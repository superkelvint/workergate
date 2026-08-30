use strict;
use warnings;

use lib 't/lib';
use Test::More;
use Time::HiRes qw(sleep);
use JSON::PP qw(decode_json);
use TestUtil qw(new_fixture spawn_master reap_pid wait_until);

my $fixture = new_fixture();
my $master = spawn_master(%$fixture, max => 1, label => 'orphaned-worker', seconds => 0.8);
wait_until(sub {
    my $path = "$fixture->{lock_dir}/slot-01.json";
    return 0 unless -e $path;
    open my $fh, '<', $path or return 0;
    local $/;
    my $data = eval { decode_json(<$fh>) };
    close $fh;
    return ref($data) eq 'HASH' && $data->{pid};
}, 2, 'started worker metadata');
kill 9, $master;
my $status = reap_pid($master);
is($status & 127, 9, 'master was killed');

my $during = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}" --max-workers 1};
like($during, qr/Running\s+: 1/, 'executed child retains lock after master death');
like($during, qr/orphaned-worker/, 'metadata still identifies orphaned worker');

wait_until(sub {
    my $out = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}" --max-workers 1};
    return $out =~ /Running\s+: 0/;
}, 2, 'orphaned worker to release lock');
pass('kernel releases orphaned worker slot at worker exit');

done_testing;
