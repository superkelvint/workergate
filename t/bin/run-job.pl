use strict;
use warnings;

use WorkerGate;

my ($lock_dir, $log_file, $max, $label, $seconds) = @ARGV;
my $gate = WorkerGate->new(
    lock_dir => $lock_dir,
    log_file => $log_file,
    max_workers => $max,
);
$gate->launch(
    directory => '.',
    command => [$^X, '-e', 'select undef, undef, undef, shift', $seconds],
    label => $label,
);
$gate->wait_all;
