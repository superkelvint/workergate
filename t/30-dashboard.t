use strict;
use warnings;

use lib 't/lib';
use Fcntl qw(:DEFAULT :flock);
use Test::More;
use TestUtil qw(new_fixture spawn_master reap_pid wait_until);

my $fixture = new_fixture();
my $holder = spawn_master(%$fixture, max => 1, label => 'running-job', seconds => 1.0);
wait_until(sub {
    my $path = "$fixture->{lock_dir}/slot-01.lock";
    return 0 unless -e $path;
    sysopen(my $fh, $path, O_RDWR) or return 0;
    my $busy = !flock($fh, LOCK_EX | LOCK_NB);
    close $fh;
    return $busy;
}, 2, 'holder to occupy slot');

my $waiter = spawn_master(%$fixture, max => 1, label => 'queued-job', seconds => 0.1);
wait_until(sub { scalar glob "$fixture->{lock_dir}/queue-*.lock" }, 2, 'queue marker');

my $output = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}" --max-workers 1};
is($? >> 8, 0, 'dashboard exits successfully');
like($output, qr/Running\s+: 1/, 'dashboard reports kernel-locked capacity');
like($output, qr/Free\s+: 0/, 'dashboard reports no free slots');
like($output, qr/Queued\s+: 1/, 'dashboard reports live queue marker');
like($output, qr/running-job/, 'dashboard identifies running job');
like($output, qr/queued-job/, 'dashboard identifies queued job');
like($output, qr/Slots\s+: X/, 'slot map marks occupied slot');

is(reap_pid($holder), 0, 'holder master finishes');
is(reap_pid($waiter), 0, 'waiting master subsequently finishes');

my $idle = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}" --max-workers 1};
like($idle, qr/Running\s+: 0/, 'dashboard becomes idle after work');
like($idle, qr/Queued\s+: 0/, 'queue becomes empty after work');

done_testing;
