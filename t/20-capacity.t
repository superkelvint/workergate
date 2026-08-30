use strict;
use warnings;

use lib 't/lib';
use Test::More;
use Time::HiRes qw(time);
use WorkerGate;
use TestUtil qw(new_fixture read_events);

my $fixture = new_fixture();
my $gate = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 2,
);
my $worker = [$^X, '-e', 'select undef,undef,undef,0.45'];
$gate->launch(directory => '.', command => $worker, label => 'one');
$gate->launch(directory => '.', command => $worker, label => 'two');
my $before = time();
$gate->launch(directory => '.', command => $worker, label => 'three');
my $blocked_for = time() - $before;
cmp_ok($blocked_for, '>=', 0.25, 'third launch waits before forking when both slots are full');
cmp_ok($gate->active_children, '<=', 2, 'master never tracks more children than capacity');
$gate->wait_all;

my @lifecycle = grep { $_->{event} eq 'STARTED' || $_->{event} eq 'FINISHED' }
    @{read_events($fixture->{log_file})};
my $active = 0;
my $peak = 0;
for my $event (@lifecycle) {
    $active += $event->{event} eq 'STARTED' ? 1 : -1;
    $peak = $active if $active > $peak;
}
is($peak, 2, 'audit log confirms peak concurrency of exactly two');
is($active, 0, 'all started jobs finished');

done_testing;
