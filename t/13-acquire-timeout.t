use strict;
use warnings;

use lib 't/lib';
use Fcntl qw(:DEFAULT :flock);
use Test::More;
use Time::HiRes qw(time);
use WorkerGate;
use TestUtil qw(new_fixture read_events);

my $fixture = new_fixture();
my $gate = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 1,
);
my $slot = "$fixture->{lock_dir}/slot-01.lock";
sysopen(my $holder, $slot, O_RDWR | O_CREAT, 0644) or die "open slot: $!";
flock($holder, LOCK_EX) or die "lock slot: $!";

my $started = time();
eval {
    $gate->launch(
        directory => '.', command => [$^X, '-e', 'exit 0'],
        label => 'times-out', timeout => 0.15,
    );
};
my $elapsed = time() - $started;
like($@, qr/timed out/i, 'launch reports capacity timeout');
cmp_ok($elapsed, '>=', 0.10, 'launch waited for capacity');
cmp_ok($elapsed, '<', 0.7, 'launch timeout is bounded');
is($gate->active_children, 0, 'timeout does not fork a worker');

my $events = read_events($fixture->{log_file});
is_deeply([map { $_->{event} } @$events], [qw(QUEUED TIMED_OUT)], 'timeout has an explicit terminal audit event');
my @markers = glob "$fixture->{lock_dir}/queue-*.lock";
is(scalar @markers, 0, 'timeout removes its live queue marker');

close $holder;
done_testing;
