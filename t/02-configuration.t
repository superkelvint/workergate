use strict;
use warnings;

use lib 't/lib';
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture);

my $fixture = new_fixture();

eval { WorkerGate->new(lock_dir => 'relative-locks', log_file => $fixture->{log_file}) };
like($@, qr/lock_dir.*absolute/i, 'relative lock directory is rejected');

eval { WorkerGate->new(lock_dir => $fixture->{lock_dir}, log_file => 'relative.log') };
like($@, qr/log_file.*absolute/i, 'relative log file is rejected');

my $first = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 2,
);
isa_ok($first, 'WorkerGate', 'first gate establishes configuration');
ok(-e "$fixture->{lock_dir}/gate-config.json", 'gate configuration is persisted');

my $same = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 2,
);
isa_ok($same, 'WorkerGate', 'matching configuration is accepted');

eval {
    WorkerGate->new(
        lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 3,
    );
};
like($@, qr/configuration mismatch.*max_workers/i, 'capacity mismatch is rejected');

eval {
    WorkerGate->new(
        lock_dir => $fixture->{lock_dir}, log_file => "$fixture->{root}/other.jsonl", max_workers => 2,
    );
};
like($@, qr/configuration mismatch.*log_file/i, 'audit-path mismatch is rejected');

my $output = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}"};
is($? >> 8, 0, 'dashboard reads persisted capacity');
like($output, qr/Capacity\s+: 2/, 'dashboard uses configured capacity by default');

$output = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}" --max-workers 3 2>&1};
is($? >> 8, 2, 'dashboard rejects a mismatched explicit capacity');
like($output, qr/configuration mismatch/i, 'dashboard explains capacity mismatch');

done_testing;
