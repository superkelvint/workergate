use strict;
use warnings;

use lib 't/lib';
use Fcntl qw(:DEFAULT :flock);
use Test::More;
use Time::HiRes qw(time);
use WorkerGate;
use TestUtil qw(new_fixture);

my $fixture = new_fixture();
sysopen(my $log_lock, $fixture->{log_file}, O_WRONLY | O_APPEND | O_CREAT, 0644)
    or die "open log: $!";
flock($log_lock, LOCK_EX) or die "lock log: $!";

my $gate = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file},
    max_workers => 1, log_lock_timeout => 0.05,
);
my @warnings;
my $started = time();
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $gate->launch(directory => '.', command => [$^X, '-e', 'exit 0'], label => 'log-contention');
    $gate->wait_all;
}
my $elapsed = time() - $started;

cmp_ok($elapsed, '<', 0.8, 'stuck audit lock cannot freeze worker scheduling');
like(join('', @warnings), qr/log.*lock.*timeout/i, 'bounded logging failure is reported');
close $log_lock;

done_testing;
