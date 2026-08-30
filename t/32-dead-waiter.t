use strict;
use warnings;

use lib 't/lib';
use Fcntl qw(:DEFAULT :flock);
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture spawn_master reap_pid wait_until);

my $fixture = new_fixture();
my $slot = "$fixture->{lock_dir}/slot-01.lock";
sysopen(my $lock_fh, $slot, O_RDWR | O_CREAT, 0644) or die "open $slot: $!";
flock($lock_fh, LOCK_EX) or die "lock $slot: $!";

my $waiter = spawn_master(%$fixture, max => 1, label => 'soon-dead-waiter', seconds => 0.1);
wait_until(sub {
    opendir my $dh, $fixture->{lock_dir} or return 0;
    my @markers = grep { /^queue-.*\.lock$/ } readdir $dh;
    closedir $dh;
    return @markers;
}, 2, 'waiter queue marker');

kill 9, $waiter;
is(reap_pid($waiter) & 127, 9, 'waiting master was killed');
my $output = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}" --max-workers 1};
like($output, qr/Queued\s+: 0/, 'unlocked stale marker is not reported as queued');
unlike($output, qr/soon-dead-waiter/, 'dead waiter label is omitted');

WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file},
    max_workers => 1, stale_file_age => 0,
);
my @stale = glob "$fixture->{lock_dir}/queue-*.lock";
is(scalar @stale, 0, 'a later gate safely reclaims the dead waiter marker');

close $lock_fh;
done_testing;
