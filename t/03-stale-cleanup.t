use strict;
use warnings;

use lib 't/lib';
use Fcntl qw(:DEFAULT :flock);
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture);

my $fixture = new_fixture();
my $stale_queue = "$fixture->{lock_dir}/queue-stale.lock";
my $active_queue = "$fixture->{lock_dir}/queue-active.lock";
my $stale_temp = "$fixture->{lock_dir}/.workergate-stale";
my $active_temp = "$fixture->{lock_dir}/.workergate-active";

for my $path ($stale_queue, $active_queue, $stale_temp, $active_temp) {
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} "{}\n";
    close $fh;
    utime(time() - 120, time() - 120, $path);
}

sysopen(my $active_fh, $active_queue, O_RDONLY) or die "open $active_queue: $!";
flock($active_fh, LOCK_EX) or die "lock $active_queue: $!";
sysopen(my $active_temp_fh, $active_temp, O_RDONLY) or die "open $active_temp: $!";
flock($active_temp_fh, LOCK_EX) or die "lock $active_temp: $!";

WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file},
    max_workers => 1, stale_file_age => 60,
);

ok(!-e $stale_queue, 'old unlocked queue marker is removed');
ok(!-e $stale_temp, 'old abandoned metadata tempfile is removed');
ok(-e $active_queue, 'old but actively locked queue marker is preserved');
ok(-e $active_temp, 'old but actively locked temporary file is preserved');

close $active_fh;
close $active_temp_fh;
done_testing;
