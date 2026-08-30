use strict;
use warnings;

use lib 't/lib';
use Fcntl qw(:DEFAULT :flock);
use JSON::PP qw(encode_json);
use Test::More;
use WorkerGate;
use TestUtil qw(new_fixture reap_pid);

my $fixture = new_fixture();
WorkerGate->new(
    lock_dir => $fixture->{lock_dir}, log_file => $fixture->{log_file}, max_workers => 1,
);

pipe(my $ready_read, my $ready_write) or die "pipe: $!";
pipe(my $stop_read, my $stop_write) or die "pipe: $!";
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    close $ready_read;
    close $stop_write;
    my $job = { job_id => 'transition-job', label => 'transition-job', queued_at => time(), slot => 1, pid => $$ };
    my $slot = "$fixture->{lock_dir}/slot-01.lock";
    sysopen(my $slot_fh, $slot, O_RDWR | O_CREAT, 0644) or die "open slot: $!";
    flock($slot_fh, LOCK_EX) or die "lock slot: $!";
    open my $metadata, '>', "$fixture->{lock_dir}/slot-01.json" or die "metadata: $!";
    print {$metadata} encode_json($job), "\n";
    close $metadata;
    my $queue = "$fixture->{lock_dir}/queue-transition-job.lock";
    sysopen(my $queue_fh, $queue, O_RDWR | O_CREAT | O_EXCL, 0644) or die "queue: $!";
    print {$queue_fh} encode_json($job), "\n";
    flock($queue_fh, LOCK_EX) or die "lock queue: $!";
    print {$ready_write} "1";
    close $ready_write;
    scalar <$stop_read>;
    close $queue_fh;
    unlink $queue;
    close $slot_fh;
    exit 0;
}

close $ready_write;
close $stop_read;
scalar <$ready_read>;
close $ready_read;

my $output = qx{$^X bin/worker-gate-status --lock-dir "$fixture->{lock_dir}"};
like($output, qr/Running\s+: 1/, 'transitioning job occupies capacity');
like($output, qr/Queued\s+: 0/, 'same job is not double-counted as queued');
is(scalar(() = $output =~ /transition-job/g), 1, 'transitioning job is rendered once');

print {$stop_write} "1\n";
close $stop_write;
is(reap_pid($pid), 0, 'transition fixture exits cleanly');

done_testing;
