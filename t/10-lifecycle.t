use strict;
use warnings;

use lib 't/lib';
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture read_events);

my $fixture = new_fixture();
my $gate = WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 2,
);
my $pid = $gate->launch(
    directory => $fixture->{root},
    command => [$^X, '-e', 'exit 7'],
    label => 'exit-seven',
);
ok($pid > 0, 'launch returns child PID');
is($gate->active_children, 1, 'child is tracked');
$gate->wait_all;
is($gate->active_children, 0, 'wait_all reaps child');

my $events = read_events($fixture->{log_file});
is_deeply([map { $_->{event} } @$events], [qw(QUEUED STARTED FINISHED)], 'complete lifecycle logged in order');
is($events->[0]{label}, 'exit-seven', 'waiting label logged');
is_deeply($events->[0]{command}, [$^X, '-e', 'exit 7'], 'command logged as JSON array');
is($events->[1]{pid}, $pid, 'started PID logged');
is($events->[2]{exit_code}, 7, 'exit code logged');
is($events->[2]{signal}, 0, 'zero signal logged');
is($events->[0]{job_id}, $events->[2]{job_id}, 'job ID stable across lifecycle');
ok($events->[2]{duration} >= 0, 'duration logged');
like($events->[0]{time}, qr/^\d{4}-\d\d-\d\d /, 'human-readable time logged');

done_testing;
