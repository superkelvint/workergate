package TestUtil;

use strict;
use warnings;

use Exporter qw(import);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Time::HiRes qw(time sleep);

our @EXPORT_OK = qw(new_fixture read_events wait_until spawn_master reap_pid);

sub new_fixture {
    my $root = tempdir(CLEANUP => 1);
    my $lock_dir = "$root/locks";
    mkdir $lock_dir or die "mkdir $lock_dir: $!";
    return {
        root => $root,
        lock_dir => $lock_dir,
        log_file => "$root/events.jsonl",
    };
}

sub read_events {
    my ($path) = @_;
    return [] unless -e $path;
    open my $fh, '<', $path or die "open $path: $!";
    my @events;
    while (my $line = <$fh>) {
        next unless $line =~ /\S/;
        push @events, decode_json($line);
    }
    close $fh;
    return \@events;
}

sub wait_until {
    my ($code, $timeout, $description) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 if $code->();
        sleep 0.02;
    }
    die "Timed out waiting for $description";
}

sub spawn_master {
    my (%args) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        exec {$^X} $^X, '-Ilib', 't/bin/run-job.pl',
            $args{lock_dir}, $args{log_file}, $args{max},
            $args{label}, $args{seconds};
        die "exec test master: $!";
    }
    return $pid;
}

sub reap_pid {
    my ($pid) = @_;
    waitpid($pid, 0);
    return $?;
}

1;
