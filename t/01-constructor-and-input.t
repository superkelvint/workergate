use strict;
use warnings;

use lib 't/lib';
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture);

my $fixture = new_fixture();
my $gate = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 2,
);
isa_ok($gate, 'WorkerGate');
is($gate->active_children, 0, 'starts with no children');

for my $bad (0, -1, 1.5, 'three', '') {
    eval { WorkerGate->new(lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => $bad) };
    like($@, qr/positive integer/, "rejects max_workers '$bad'");
}

eval { $gate->launch(command => [$^X, '-e', 'exit']) };
like($@, qr/directory required/, 'directory is required');
for my $command (undef, 'echo', [], [undef], [{}]) {
    eval { $gate->launch(directory => '.', command => $command) };
    like($@, qr/command/, 'rejects malformed command');
}
eval { $gate->launch(directory => '.', command => [$^X], label => {}) };
like($@, qr/label must be a scalar/, 'rejects reference label');

done_testing;
