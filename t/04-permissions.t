use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;
use WorkerGate;

my $root = tempdir(CLEANUP => 1);
my $lock_dir = "$root/secure-locks";
my $log_file = "$root/events.jsonl";
my $old_umask = umask 0;
my $gate = WorkerGate->new(
    lock_dir => $lock_dir, log_file => $log_file, max_workers => 1,
);
$gate->launch(directory => '.', command => [$^X, '-e', 'exit 0'], label => 'permissions');
$gate->wait_all;
umask $old_umask;

is((stat($lock_dir))[2] & 0777, 0750, 'new lock directory is private by default');
is((stat("$lock_dir/gate-config.json"))[2] & 0777, 0640, 'configuration metadata is not world-readable');
is((stat("$lock_dir/slot-01.lock"))[2] & 0777, 0640, 'slot file is not world-readable');
is((stat("$lock_dir/slot-01.json"))[2] & 0777, 0640, 'job metadata is not world-readable');
is((stat($log_file))[2] & 0777, 0640, 'audit log is not world-readable');

done_testing;
