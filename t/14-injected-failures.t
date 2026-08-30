use strict;
use warnings;

use lib 't/lib';
use Errno qw(EAGAIN);
use Fcntl qw(:DEFAULT :flock);
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture read_events);

{
    package ForkFailureGate;
    use parent 'WorkerGate';
    sub _fork { $! = Errno::EAGAIN(); return }
}

{
    package MetadataFailureGate;
    use parent 'WorkerGate';
    sub _write_json_atomic {
        my ($self, @args) = @_;
        die "injected metadata failure\n" if $self->{inject_metadata_failure};
        return $self->SUPER::_write_json_atomic(@args);
    }
}

sub slot_is_free {
    my ($path) = @_;
    sysopen(my $fh, $path, O_RDWR | O_CREAT, 0644) or die "open slot: $!";
    my $free = flock($fh, LOCK_EX | LOCK_NB);
    close $fh;
    return $free;
}

my $fork_fixture = new_fixture();
my $fork_gate = ForkFailureGate->new(
    lock_dir => $fork_fixture->{lock_dir}, log_file => $fork_fixture->{log_file}, max_workers => 1,
);
eval { $fork_gate->launch(directory => '.', command => [$^X, '-e', 'exit 0'], label => 'fork-fails') };
like($@, qr/fork failed/i, 'injected fork failure reaches caller');
ok(slot_is_free("$fork_fixture->{lock_dir}/slot-01.lock"), 'fork failure releases reserved slot');
is_deeply(
    [map { $_->{event} } @{read_events($fork_fixture->{log_file})}],
    [qw(QUEUED FORK_FAILED)],
    'fork failure is audited',
);

my $metadata_fixture = new_fixture();
my $metadata_gate = MetadataFailureGate->new(
    lock_dir => $metadata_fixture->{lock_dir}, log_file => $metadata_fixture->{log_file}, max_workers => 1,
);
$metadata_gate->{inject_metadata_failure} = 1;
eval { $metadata_gate->launch(directory => '.', command => [$^X, '-e', 'exit 0'], label => 'metadata-fails') };
like($@, qr/injected metadata failure/, 'pre-fork metadata failure reaches caller');
ok(slot_is_free("$metadata_fixture->{lock_dir}/slot-01.lock"), 'metadata failure releases reserved slot');
is_deeply(
    [map { $_->{event} } @{read_events($metadata_fixture->{log_file})}],
    [qw(QUEUED GATE_FAILED)],
    'gate setup failure is audited',
);

done_testing;
