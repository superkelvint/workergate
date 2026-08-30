use strict;
use warnings;

use lib 't/lib';
use File::Spec;
use Test::More;
use TestUtil qw(new_fixture);

my $fixture = new_fixture();
sub quiet_system {
    open my $saved_stderr, '>&', \*STDERR or die "save STDERR: $!";
    open STDERR, '>', File::Spec->devnull or die "redirect STDERR: $!";
    my $result = system @_;
    open STDERR, '>&', $saved_stderr or die "restore STDERR: $!";
    close $saved_stderr;
    return $result;
}
my $exit = quiet_system($^X, 'bin/worker-gate-status', '--lock-dir', 'relative-locks');
is($exit >> 8, 2, 'dashboard rejects a relative lock directory');
my $missing = "$fixture->{root}/missing-lock-directory";
$exit = quiet_system($^X, 'bin/worker-gate-status', '--lock-dir', $missing);
is($exit >> 8, 2, 'dashboard rejects a missing lock directory');

$exit = quiet_system($^X, 'bin/worker-gate-status', '--lock-dir', $fixture->{lock_dir}, '--max-workers', '0');
is($exit >> 8, 2, 'dashboard rejects zero capacity');

$exit = quiet_system($^X, 'bin/worker-gate-status', '--lock-dir', $fixture->{lock_dir}, '--interval', '0');
is($exit >> 8, 2, 'dashboard rejects zero watch interval');

$exit = system($^X, 'bin/worker-gate-status', '--help');
is($exit, 0, 'dashboard help exits successfully');

done_testing;
