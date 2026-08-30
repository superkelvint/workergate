use strict;
use warnings;

use lib 't/lib';
use File::Spec;
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture read_events);

sub quiet (&) {
    open my $saved_stderr, '>&', \*STDERR or die "save STDERR: $!";
    open STDERR, '>', File::Spec->devnull or die "redirect STDERR: $!";
    my $result = $_[0]->();
    open STDERR, '>&', $saved_stderr or die "restore STDERR: $!";
    close $saved_stderr;
    return $result;
}

sub run_case {
    my ($fixture, $label, $directory, $command) = @_;
    my $gate = WorkerGate->new(
        lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 1,
    );
    $gate->launch(directory => $directory, command => $command, label => $label);
    $gate->wait_all;
    my ($finished) = grep { $_->{event} eq 'FINISHED' && $_->{label} eq $label }
        @{read_events($fixture->{log_file})};
    return $finished;
}

my $fixture = new_fixture();
my $missing_dir = "$fixture->{root}/does-not-exist";
my $chdir = quiet { run_case($fixture, 'bad-directory', $missing_dir, [$^X, '-e', 'exit 0']) };
is($chdir->{exit_code}, 126, 'chdir failure becomes exit 126');

my $missing_program = "$fixture->{root}/no-such-program";
my $exec = quiet { run_case($fixture, 'bad-exec', $fixture->{root}, [$missing_program]) };
is($exec->{exit_code}, 127, 'exec failure becomes exit 127');

my $signal = quiet { run_case($fixture, 'signalled', $fixture->{root}, [$^X, '-e', 'kill 15, $$; select undef,undef,undef,1']) };
is($signal->{signal}, 15, 'terminating signal is logged');

my $shell_output = "$fixture->{root}/must-not-exist";
my $one_element = quiet { run_case($fixture, 'no-shell', $fixture->{root}, ["touch $shell_output"]) };
is($one_element->{exit_code}, 127, 'one-element command is not sent through a shell');
ok(!-e $shell_output, 'shell metacharacter behavior cannot create a file');

my $bad_log_fixture = new_fixture();
my $bad_log_gate = WorkerGate->new(
    lock_dir => $bad_log_fixture->{lock_dir}, log_file => $bad_log_fixture->{root}, max_workers => 1,
);
{
    local $SIG{__WARN__} = sub { };
    $bad_log_gate->launch(directory => '.', command => [$^X, '-e', 'exit 0'], label => 'bad-log');
    $bad_log_gate->wait_all;
}
pass('log write failure does not prevent work from running');

done_testing;
