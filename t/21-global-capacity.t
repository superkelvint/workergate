use strict;
use warnings;

use lib 't/lib';
use Test::More;
use Time::HiRes qw(time);
use TestUtil qw(new_fixture read_events spawn_master reap_pid);

my $fixture = new_fixture();
my $start = time();
my $first = spawn_master(%$fixture, max => 1, label => 'master-one', seconds => 0.40);
my $second = spawn_master(%$fixture, max => 1, label => 'master-two', seconds => 0.40);
is(reap_pid($first), 0, 'first independent master succeeds');
is(reap_pid($second), 0, 'second independent master succeeds');
my $elapsed = time() - $start;
cmp_ok($elapsed, '>=', 0.68, 'unrelated masters share the one-slot global limit');

my $events = read_events($fixture->{log_file});
is(scalar(grep { $_->{event} eq 'STARTED' } @$events), 2, 'both jobs started');
is(scalar(grep { $_->{event} eq 'FINISHED' } @$events), 2, 'both jobs finished');
is_deeply([sort map { $_->{slot} } grep { $_->{event} eq 'STARTED' } @$events], [1, 1], 'both masters used the same slot namespace');

done_testing;
