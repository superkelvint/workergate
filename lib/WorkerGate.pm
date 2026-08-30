package WorkerGate;

use strict;
use warnings;

use Errno qw(EAGAIN EWOULDBLOCK EINTR ENOENT);
use Fcntl qw(:DEFAULT :flock F_GETFD F_SETFD FD_CLOEXEC);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP qw(decode_json encode_json);
use POSIX qw(WNOHANG _exit strftime);
use Time::HiRes qw(time sleep);

our $VERSION = '0.03';

sub new {
    my ($class, %args) = @_;

    # An environment override lets existing callers retain their old
    # max_workers argument while operations changes the shared limit once.
    my $environment_max = exists($ENV{WORKER_GATE_MAX_WORKERS})
        ? $ENV{WORKER_GATE_MAX_WORKERS} : undef;
    my $caller_max = exists($args{max_workers})
        ? $args{max_workers} : undef;
    my $max_workers = defined($environment_max)
        ? $environment_max : ($caller_max // 30);
    die "max_workers must be a positive integer\n"
        unless defined($max_workers) && $max_workers =~ /\A[1-9][0-9]*\z/;

    my $lock_dir = $args{lock_dir} // '/run/lock/store-worker-gate';
    my $log_file = $args{log_file} // '/var/log/store-worker-gate.jsonl';
    die "lock_dir must not be empty\n" unless length $lock_dir;
    die "log_file must not be empty\n" unless length $log_file;
    die "lock_dir must be an absolute path\n"
        unless File::Spec->file_name_is_absolute($lock_dir);
    die "log_file must be an absolute path\n"
        unless File::Spec->file_name_is_absolute($log_file);

    my $log_lock_timeout = _nonnegative_number(
        $args{log_lock_timeout} // 0.25, 'log_lock_timeout',
    );
    my $control_lock_timeout = _nonnegative_number(
        $args{control_lock_timeout} // 2, 'control_lock_timeout',
    );
    my $stale_file_age = _nonnegative_number(
        $args{stale_file_age} // 86400, 'stale_file_age',
    );
    my $file_mode = _file_mode($args{file_mode} // 0640);
    my $dir_mode = _file_mode($args{dir_mode} // 0750);

    make_path($lock_dir, { mode => $dir_mode }) unless -d $lock_dir;
    die "lock_dir '$lock_dir' is not a directory\n" unless -d $lock_dir;

    my $self = bless {
        max_workers => 0 + $max_workers,
        environment_max => defined($environment_max) ? 1 : 0,
        max_explicit => defined($environment_max) || defined($caller_max),
        lock_dir    => $lock_dir,
        log_file    => $log_file,
        log_lock_timeout => $log_lock_timeout,
        control_lock_timeout => $control_lock_timeout,
        stale_file_age => $stale_file_age,
        file_mode => $file_mode,
        children    => {},
        sequence    => 0,
    }, $class;

    $self->_ensure_configuration;
    $self->_cleanup_stale_files;
    return $self;
}

sub _nonnegative_number {
    my ($value, $name) = @_;
    die "$name must be a non-negative number\n"
        unless defined($value) && !ref($value)
            && $value =~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/;
    return 0 + $value;
}

sub _file_mode {
    my ($value) = @_;
    die "file mode must be an integer between 0 and 0777\n"
        unless defined($value) && !ref($value) && $value =~ /\A[0-9]+\z/
            && $value >= 0 && $value <= 0777;
    return 0 + $value;
}

sub _iso_time {
    my ($epoch) = @_;
    my @local = localtime($epoch);
    return strftime('%Y-%m-%d %H:%M:%S', @local);
}

sub _write_all {
    my ($fh, $text, $description) = @_;
    my $offset = 0;
    while ($offset < length $text) {
        my $written = syswrite($fh, $text, length($text) - $offset, $offset);
        if (!defined $written) {
            next if $! == EINTR;
            die "Cannot write $description: $!\n";
        }
        die "Short write of zero bytes to $description\n" if $written == 0;
        $offset += $written;
    }
}

sub _flock_nonblocking {
    my ($fh, $operation, $description) = @_;
    while (1) {
        return 1 if flock($fh, $operation | LOCK_NB);
        my $error = 0 + $!;
        my $message = "$!";
        next if $error == EINTR;
        return 0 if $error == EWOULDBLOCK || $error == EAGAIN;
        die "Cannot lock $description: $message\n";
    }
}

sub _lock_until {
    my ($self, $fh, $description, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (!_flock_nonblocking($fh, LOCK_EX, $description)) {
        return 0 if time() >= $deadline;
        sleep(0.01);
    }
    return 1;
}

sub _log {
    my ($self, %data) = @_;
    my $now = time();
    $data{timestamp} //= $now;
    $data{time}      //= _iso_time($data{timestamp});

    my $line = eval { encode_json(\%data) . "\n" };
    if (!defined $line) {
        warn "WorkerGate: cannot encode log event: $@";
        return;
    }

    sysopen(my $fh, $self->{log_file}, O_WRONLY | O_APPEND | O_CREAT, $self->{file_mode})
        or do { warn "WorkerGate: cannot write $self->{log_file}: $!\n"; return };
    unless ($self->_lock_until(
        $fh, $self->{log_file}, $self->{log_lock_timeout},
    )) {
        warn "WorkerGate: log lock timeout for $self->{log_file}\n";
        close $fh;
        return;
    }
    eval { _write_all($fh, $line, $self->{log_file}); 1 }
        or warn "WorkerGate: $@";
    close $fh or warn "WorkerGate: cannot close $self->{log_file}: $!\n";
}

sub _new_job_id {
    my ($self) = @_;
    return sprintf '%d-%d-%d', $$, ++$self->{sequence}, int(time() * 1_000_000);
}

sub _slot_path {
    my ($self, $slot) = @_;
    return sprintf '%s/slot-%02d.lock', $self->{lock_dir}, $slot;
}

sub _metadata_path {
    my ($self, $slot) = @_;
    return sprintf '%s/slot-%02d.json', $self->{lock_dir}, $slot;
}

sub _configuration_path {
    my ($self) = @_;
    return "$self->{lock_dir}/gate-config.json";
}

sub _gate_is_idle {
    my ($self, $other_max) = @_;
    my $max = $self->{max_workers} > $other_max
        ? $self->{max_workers} : $other_max;

    for my $slot (1 .. $max) {
        my $path = $self->_slot_path($slot);
        my $fh;
        if (!sysopen($fh, $path, O_RDONLY)) {
            next if $! == ENOENT;
            die "Cannot inspect $path: $!\n";
        }
        my $free = eval { _flock_nonblocking($fh, LOCK_EX, $path) };
        my $error = $@;
        close $fh;
        die $error if length $error;
        return 0 unless $free;
    }

    opendir my $directory, $self->{lock_dir}
        or die "Cannot scan $self->{lock_dir}: $!\n";
    my @queue = grep { /\Aqueue-.*\.lock\z/ } readdir $directory;
    closedir $directory;
    for my $file (@queue) {
        my $path = "$self->{lock_dir}/$file";
        sysopen(my $fh, $path, O_RDONLY) or next;
        my $free = eval { _flock_nonblocking($fh, LOCK_EX, $path) };
        my $error = $@;
        close $fh;
        die $error if length $error;
        return 0 unless $free;
    }
    return 1;
}

sub _read_json_path {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh or die "Cannot close $path: $!\n";
    my $data = eval { decode_json($text // '') };
    die "Cannot decode $path: $@" unless ref($data) eq 'HASH';
    return $data;
}

sub _write_json_atomic {
    my ($self, $path, $data) = @_;
    my $json = encode_json($data) . "\n";
    my ($fh, $temporary) = tempfile('.workergate-XXXXXX', DIR => $self->{lock_dir}, UNLINK => 0);
    eval {
        _flock_nonblocking($fh, LOCK_EX, $temporary)
            or die "Cannot lock new metadata temporary $temporary\n";
        _write_all($fh, $json, $temporary);
        chmod $self->{file_mode}, $temporary or die "Cannot chmod $temporary: $!\n";
        rename $temporary, $path or die "Cannot rename $temporary to $path: $!\n";
        close($fh) or die "Cannot close $path: $!\n";
        1;
    } or do {
        my $error = $@ || "Cannot write $path\n";
        close $fh if defined fileno $fh;
        unlink $temporary;
        die $error;
    };
}

sub _ensure_configuration {
    my ($self) = @_;
    my $lock_path = "$self->{lock_dir}/gate-config.lock";
    sysopen(my $fh, $lock_path, O_RDWR | O_CREAT, $self->{file_mode})
        or die "Cannot open $lock_path: $!\n";
    $self->_lock_until(
        $fh, $lock_path, $self->{control_lock_timeout},
    ) or die "Timed out locking $lock_path\n";

    my $path = $self->_configuration_path;
    if (-e $path) {
        my $configuration = _read_json_path($path);
        die "Unsupported WorkerGate configuration format in $path\n"
            unless ($configuration->{format_version} // 0) == 1;
        my $max_changed;
        if (!defined($configuration->{max_workers})
            || $configuration->{max_workers} != $self->{max_workers}) {
            if (!$self->{max_explicit}
                && defined($configuration->{max_workers})
                && $configuration->{max_workers} =~ /\A[1-9][0-9]*\z/) {
                # Omitting max_workers means “use the shared deployment value”.
                $self->{max_workers} = 0 + $configuration->{max_workers};
            } else {
            die "WorkerGate configuration mismatch: max_workers is $configuration->{max_workers}, requested $self->{max_workers}\n"
                unless $self->{environment_max};
            my $old_max = $configuration->{max_workers} // 0;
            die "Cannot change max_workers while the gate is active; stop old masters and drain workers first\n"
                unless $self->_gate_is_idle($old_max);
            $max_changed = 1;
            }
        }
        die "WorkerGate configuration mismatch: log_file is '$configuration->{log_file}', requested '$self->{log_file}'\n"
            unless defined($configuration->{log_file})
                && $configuration->{log_file} eq $self->{log_file};
        if ($max_changed) {
            $configuration->{max_workers} = $self->{max_workers};
            $self->_write_json_atomic($path, $configuration);
        }
    } else {
        $self->_write_json_atomic($path, {
            format_version => 1,
            max_workers => $self->{max_workers},
            log_file => $self->{log_file},
        });
    }
    close $fh or die "Cannot close $lock_path: $!\n";
    return;
}

sub _cleanup_stale_files {
    my ($self) = @_;
    my $cutoff = time() - $self->{stale_file_age};
    opendir my $directory, $self->{lock_dir}
        or do { warn "WorkerGate: cannot scan $self->{lock_dir}: $!\n"; return };
    my @files = readdir $directory;
    closedir $directory;

    for my $file (@files) {
        next unless $file =~ /\Aqueue-.*\.lock\z/ || $file =~ /\A\.workergate-/;
        my $path = "$self->{lock_dir}/$file";
        my @stat = stat $path;
        next unless @stat && $stat[9] <= $cutoff;

        sysopen(my $fh, $path, O_RDONLY) or next;
        my $unlocked = eval { _flock_nonblocking($fh, LOCK_EX, $path) };
        if ($unlocked) {
            unlink $path or warn "WorkerGate: cannot remove stale $path: $!\n";
        }
        warn "WorkerGate: cannot inspect stale $path: $@" if $@;
        close $fh;
    }
    return;
}

sub _try_slot {
    my ($self) = @_;
    my $max = $self->{max_workers};
    my $first = int(rand($max)) + 1;

    for my $offset (0 .. $max - 1) {
        my $slot = (($first - 1 + $offset) % $max) + 1;
        my $path = $self->_slot_path($slot);
        sysopen(my $fh, $path, O_RDWR | O_CREAT, $self->{file_mode})
            or die "Cannot open $path: $!\n";

        my $locked = eval { _flock_nonblocking($fh, LOCK_EX, $path) };
        if (!$locked) {
            my $exception = $@;
            close $fh;
            die $exception if length $exception;
            next;
        }

        my $flags = fcntl($fh, F_GETFD, 0);
        die "F_GETFD failed for $path: $!\n" unless defined $flags;
        $flags &= ~FD_CLOEXEC;
        defined fcntl($fh, F_SETFD, $flags)
            or die "F_SETFD failed for $path: $!\n";
        return ($slot, $fh);
    }
    return;
}

sub _create_queue_marker {
    my ($self, $job) = @_;
    my $path = "$self->{lock_dir}/queue-$job->{job_id}.lock";
    my $json = encode_json($job) . "\n";
    my ($fh, $temporary) = tempfile(
        '.workergate-queue-XXXXXX', DIR => $self->{lock_dir}, UNLINK => 0,
    );
    my $published;
    eval {
        _flock_nonblocking($fh, LOCK_EX, $temporary)
            or die "Cannot lock new queue marker $temporary\n";
        _write_all($fh, $json, $temporary);
        chmod $self->{file_mode}, $temporary
            or die "Cannot chmod $temporary: $!\n";
        link $temporary, $path
            or die "Cannot publish queue marker $path: $!\n";
        $published = 1;
        unlink $temporary
            or warn "WorkerGate: cannot remove queue temporary $temporary: $!\n";
        1;
    } or do {
        my $error = $@ || "Cannot create queue marker $path\n";
        unlink $path if $published;
        close $fh;
        unlink $temporary;
        die $error;
    };
    return ($fh, $path);
}

sub _remove_queue_marker {
    my ($fh, $path) = @_;
    unlink $path if defined($path) && -e $path;
    close $fh;
}

sub _fork {
    return fork();
}

sub _reap_finished {
    my ($self) = @_;
    for my $pid (keys %{ $self->{children} }) {
        my $result = waitpid($pid, WNOHANG);
        next if $result == 0;
        next if $result == -1 && $! == EINTR;

        my $job = delete $self->{children}{$pid};
        if ($result == -1) {
            $self->_log(
                event => 'FINISHED_UNKNOWN', job_id => $job->{job_id},
                pid => 0 + $pid, slot => $job->{slot}, label => $job->{label},
                error => "$!",
            );
            next;
        }

        my $status = $?;
        $self->_log(
            event => 'FINISHED', job_id => $job->{job_id}, pid => 0 + $pid,
            slot => $job->{slot}, label => $job->{label},
            exit_code => ($status >> 8), signal => ($status & 127),
            core_dumped => (($status & 128) ? 1 : 0),
            duration => time() - $job->{started_at},
        );
    }
}

sub launch {
    my ($self, %args) = @_;
    my $directory = $args{directory};
    die "directory required\n" unless defined($directory) && !ref($directory) && length($directory);

    my $command = $args{command};
    die "command must be a non-empty array reference\n"
        unless ref($command) eq 'ARRAY' && @$command;
    for my $part (@$command) {
        die "command elements must be defined, non-reference scalars\n"
            if !defined($part) || ref($part);
    }

    my $label = $args{label} // join(' ', @$command);
    die "label must be a scalar\n" if ref $label;
    my $timeout = exists $args{timeout}
        ? _nonnegative_number($args{timeout}, 'timeout') : undef;
    my $job_id = $self->_new_job_id;
    my $job = {
        job_id => $job_id, master_pid => 0 + $$, label => "$label",
        directory => "$directory", command => [ map { "$_" } @$command ],
        queued_at => time(),
    };

    my ($queue_fh, $queue_path) = $self->_create_queue_marker($job);
    $self->_log(event => 'QUEUED', %$job);

    my ($slot, $lock_fh);
    my $timed_out;
    my $deadline = defined($timeout) ? $job->{queued_at} + $timeout : undef;
    my $acquired = eval {
        while (!$lock_fh) {
            ($slot, $lock_fh) = $self->_try_slot;
            last if $lock_fh;
            if (defined($deadline) && time() >= $deadline) {
                $timed_out = 1;
                last;
            }
            $self->_reap_finished;
            my $delay = 0.15 + rand(0.20);
            if (defined $deadline) {
                my $remaining = $deadline - time();
                $delay = $remaining if $remaining > 0 && $remaining < $delay;
            }
            sleep($delay) if $delay > 0;
        }

        if (!$timed_out) {
            # Publish the reservation immediately so a dashboard cannot briefly
            # associate this lock with stale metadata from its previous owner.
            my $reserved_at = time();
            $self->_write_json_atomic($self->_metadata_path($slot), {
                %$job, slot => $slot, reserved_at => $reserved_at,
            });
        }
        1;
    };
    if (!$acquired) {
        my $error = $@ || "unknown gate acquisition failure\n";
        close $lock_fh if $lock_fh;
        _remove_queue_marker($queue_fh, $queue_path);
        $self->_log(event => 'GATE_FAILED', %$job, error => "$error");
        die $error;
    }

    if ($timed_out) {
        _remove_queue_marker($queue_fh, $queue_path);
        my $waited = time() - $job->{queued_at};
        $self->_log(event => 'TIMED_OUT', %$job, waited => $waited);
        die sprintf "WorkerGate: timed out waiting for capacity after %.3f seconds\n", $waited;
    }

    # The job now owns capacity and is no longer queued. A slot may have become
    # free because one of our children exited; log that finish before the new
    # STARTED event so audit-log replay agrees with actual peak capacity.
    _remove_queue_marker($queue_fh, $queue_path);
    undef $queue_fh;
    undef $queue_path;
    $self->_reap_finished;

    my $pid = $self->_fork;
    if (!defined $pid) {
        my $error = "$!";
        close $lock_fh;
        $self->_log(event => 'FORK_FAILED', %$job, slot => $slot, error => $error);
        die "fork failed: $error\n";
    }

    if ($pid == 0) {
        unless (chdir $directory) {
            print STDERR "WorkerGate: chdir '$directory' failed: $!\n";
            _exit(126);
        }
        {
            no warnings 'exec';
            exec { $command->[0] } @$command;
        }
        print STDERR "WorkerGate: exec '$command->[0]' failed: $!\n";
        _exit(127);
    }

    my $started_at = time();
    eval {
        $self->_write_json_atomic($self->_metadata_path($slot), {
            %$job, pid => 0 + $pid, slot => $slot, started_at => $started_at,
        });
        1;
    } or warn "WorkerGate: cannot update slot $slot metadata: $@";
    close $lock_fh;

    $self->{children}{$pid} = {
        job_id => $job_id, slot => $slot, label => "$label", started_at => $started_at,
    };
    $self->_log(
        event => 'STARTED', job_id => $job_id, master_pid => 0 + $$,
        pid => 0 + $pid, slot => $slot, label => "$label",
        queued_for => $started_at - $job->{queued_at},
    );
    $self->_reap_finished;
    return $pid;
}

sub wait_all {
    my ($self) = @_;
    while (keys %{ $self->{children} }) {
        $self->_reap_finished;
        sleep(0.10) if keys %{ $self->{children} };
    }
    return;
}

sub active_children {
    my ($self) = @_;
    return scalar keys %{ $self->{children} };
}

1;

=head1 NAME

WorkerGate - a small cross-process worker concurrency gate

=head1 SYNOPSIS

  my $gate = WorkerGate->new(max_workers => 30);
  $gate->launch(
      directory => '/srv/store',
      command   => ['/usr/bin/perl', 'order_process.cgi', 'amazon'],
      label     => 'Amazon orders: store163',
      timeout   => 300,
  );
  $gate->wait_all;

=head1 DESCRIPTION

Workers acquire one of a shared set of C<flock> slots before C<fork>.  The
executed worker retains the lock descriptor, so the kernel releases capacity
on every exit path, including signals and parent failure.

The lock directory and log file must be absolute paths.  The first gate using
a lock directory persists its capacity and log destination; later gates reject
configuration mismatches.  Waiting is opportunistic rather than FIFO.  Pass a
C<timeout> to C<launch> when an unbounded wait is not acceptable.

=cut
