use strict;
use warnings;

use lib 't/lib';
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture read_events);

my $fixture = new_fixture();
my $gate = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 1,
);

{
    local $SIG{CHLD} = 'IGNORE';
    $gate->launch(directory => '.', command => [$^X, '-e', 'exit 0'], label => 'auto-reaped');
    $gate->wait_all;
}

my $events = read_events($fixture->{log_file});
is_deeply(
    [map { $_->{event} } @$events],
    [qw(QUEUED STARTED FINISHED_UNKNOWN)],
    'an external child reaper produces an explicit unknown terminal event',
);
is($gate->active_children, 0, 'auto-reaped child is removed from tracking');

done_testing;
