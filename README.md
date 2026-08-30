# WorkerGate

WorkerGate stops a server from running too many order-processing jobs at once.
You give it a maximum (for example, 30), then launch every Amazon, eBay, and
storefront job through the same gate. The 31st job waits until one of the first
30 finishes.

The limit is shared by every Perl master process that uses the same gate, not
just by one invocation of your script.

## Requirements

- Linux or Unix with Perl 5
- Git, so you can download the repository
- A local filesystem with working `flock(2)` locks
- No non-core Perl modules

Do not place the lock directory on NFS unless you have verified its locking
behavior.

## Download and install WorkerGate

### 1. Download the repository

Open a terminal and run:

```sh
cd
git clone https://github.com/superkelvint/workergate.git
cd workergate
```

The first command goes to your home directory. The second command downloads
WorkerGate into a new directory named `workergate`. The third command enters
that directory. You now have the source file at `lib/WorkerGate.pm`.

If the shell says `git: command not found`, install Git first. On Debian or
Ubuntu:

```sh
sudo apt-get update
sudo apt-get install git
```

On RHEL, Rocky Linux, AlmaLinux, or Fedora:

```sh
sudo dnf install git
```

Then run the three clone commands again.

### 2. Test the downloaded code

While still inside the `workergate` directory, run:

```sh
perl Makefile.PL
make test
```

The final output should report `Result: PASS`. Do not install the module if
the tests fail.

### 3. Install `WorkerGate.pm` in `/home/shared_cgi/lib`

Still inside the downloaded `workergate` directory, run:

```sh
sudo install -d -m 0755 /home/shared_cgi/lib
sudo install -m 0644 lib/WorkerGate.pm /home/shared_cgi/lib/WorkerGate.pm
```

Confirm that Perl can find it:

```sh
perl -I/home/shared_cgi/lib -MWorkerGate -e 'print "WorkerGate installed\n"'
```

If that prints `WorkerGate installed`, the module is installed.

To update WorkerGate later, return to the downloaded repository, pull the
newest version, test it, and copy it again:

```sh
cd ~/workergate
git pull --ff-only
make test
sudo install -m 0644 lib/WorkerGate.pm /home/shared_cgi/lib/WorkerGate.pm
```

### Runtime permissions setup

By default, WorkerGate keeps its shared locks in
`/run/lock/store-worker-gate` and writes its event log to
`/var/log/store-worker-gate.jsonl`. The Unix account that runs the order
script must be able to write both places.

For example, if the order script always runs as `www-data`, run:

```sh
sudo install -d -o www-data -g www-data -m 0750 /run/lock/store-worker-gate
sudo install -o www-data -g www-data -m 0640 /dev/null /var/log/store-worker-gate.jsonl
```

Replace `www-data` with the actual account that runs your script. All masters
sharing one gate should normally run as that same account. Do not make either
location world-writable. On systems that clear `/run` during reboot, recreate
the lock directory from your normal boot/startup setup before order jobs run.

## Convert an existing master script

Amazon, eBay, and storefront do **not** have to be in one Perl file. Each
master script creates its own `WorkerGate` object. The objects enforce one
combined 30-worker limit because they all use the same default lock directory,
`/run/lock/store-worker-gate`.

Use the following four-step conversion in every master script:

1. Load WorkerGate near the top of the file.
2. Create one gate before the loop that launches jobs.
3. Replace the script's manual `fork` and `exec` with `$gate->launch(...)`.
4. Call `$gate->wait_all()` immediately after the loop.

### Example migration `multi_store_order_process_ebay.cgi`

#### Before

The current file manually forks and executes `ebay_update_queue.cgi`:

```perl
foreach $event(@events)
{

    $ARGV[0] eq "testing" and print "$event\n";

    $path = "/home/$event/public_html/online_store";

    sleep(4);

    !-e "$path/ebay_update_queue.cgi" and next;

    my $pid = fork();

    # if $pid is NOT defined, something broke
    defined $pid or die "Couldn't fork for some reason: $!\n";

    # $pid equals 0 in child, so if it's 'true' we're the parent
    # and we loop to the next event in the list...
    $pid and next;

    # ok, we're the child, execute the event and it's items
    -e "$path/ebay_update_queue.cgi" and do{

        &time;
        $log_line = "$path/ebay_update_queue.cgi\n";
        &log;

        my $cmd = "perl $path/ebay_update_queue.cgi";
        exec $cmd;

    };#end do

    last;
}
```

#### After

First, add these two lines immediately below `#!/usr/bin/perl` at the top of
the file:

```perl
use lib '/home/shared_cgi/lib';
use WorkerGate;
```

Then replace the old `foreach` block with this version. The gate is created
once, before the loop—not once for every store.

```perl
my $gate = WorkerGate->new;

foreach $event (@events)
{
    $ARGV[0] eq "testing" and print "$event\n";

    $path = "/home/$event/public_html/online_store";

    # Optional: keep this only if eBay or another external API needs launches
    # to be staggered. WorkerGate limits concurrent workers, not API rate.
    sleep(4);

    !-e "$path/ebay_update_queue.cgi" and next;

    &time;
    $log_line = "$path/ebay_update_queue.cgi\n";
    &log;

    $gate->launch(
        label     => "eBay update queue: $event",
        directory => $path,
        command   => [
            '/usr/bin/perl',
            "$path/ebay_update_queue.cgi",
        ],
    );
}

$gate->wait_all();
```

`WorkerGate` now performs the `fork` and `exec`. Do not keep the old manual
`fork`, `$pid and next`, string-form `exec`, or `last` statements.

### Another example: `multi_store_order_process_amazon.cgi`

Amazon runs from a different master file. This example is taken from the
included `multi_store_order_process_amazon.cgi`. It executes the same
`order_process.cgi` used by the store, with `amazon` as the command-line
argument.

#### Before

```perl
foreach $event(@events)
{
    $ARGV[0] eq "testing" and print "$event\n";

    $path = "/home/$event/public_html/online_store";

    sleep(8);

    !-e "$path/order_process.cgi" and next;

    my $pid = fork();

    # if $pid is NOT defined, something broke
    defined $pid or die "Couldn't fork for some reason: $!\n";

    # $pid equals 0 in child, so if it's 'true' we're the parent
    # and we loop to the next event in the list...
    $pid and next;

    # ok, we're the child, execute the event and its items
    -e "$path/order_process.cgi" and do{

        &time;
        $log_line = "$path/order_process.cgi\n";
        &log;

        my $cmd = "perl $path/order_process.cgi amazon";
        exec $cmd;

    };#end do

    last;
}
```

#### After

Add WorkerGate immediately below the shebang in the Amazon file too:

```perl
use lib '/home/shared_cgi/lib';
use WorkerGate;
```

Then replace its old `foreach` block with:

```perl
my $gate = WorkerGate->new;

foreach $event (@events)
{
    $ARGV[0] eq "testing" and print "$event\n";

    $path = "/home/$event/public_html/online_store";

    # Optional: keep this only if Amazon or another external API needs launches
    # to be staggered. WorkerGate limits concurrent workers, not API rate.
    sleep(8);

    !-e "$path/order_process.cgi" and next;

    &time;
    $log_line = "$path/order_process.cgi\n";
    &log;

    $gate->launch(
        label     => "Amazon orders: $event",
        directory => $path,
        command   => [
            '/usr/bin/perl',
            "$path/order_process.cgi",
            'amazon',
        ],
    );
}

$gate->wait_all();
```

The final `'amazon'` array element is important. It replaces the `amazon`
argument at the end of the old command string.

The Perl variables are separate, but all three files still share the
same system-wide capacity:

```text
multi_store_update_process_ebay.cgi       -> its own $gate object --+
multi_store_order_process_amazon.cgi      -> its own $gate object --+-> 30 total workers
multi_store_update_process_storefront.cgi -> its own $gate object --+
```

The three important arguments to `launch` are:

- `label`: a human-readable name shown in logs and by the status command.
- `directory`: the working directory for the command. The child changes to
  this directory before it starts.
- `command`: the executable followed by its arguments. Keep this as an array;
  it is executed directly, without a shell.

`launch` returns the child PID. If all 30 shared slots are occupied, it waits
for a slot before starting the command. Always call `wait_all` after the final
`launch` in each master so that master waits for all of its own children and
records their final status.

## If you cannot use `/run/lock` or `/var/log`

Choose absolute paths writable by the account running the jobs, and give the
same paths to every `WorkerGate` instance:

```perl
my $gate = WorkerGate->new(
    lock_dir    => '/home/shared_cgi/var/worker-gate',
    log_file    => '/home/shared_cgi/var/worker-gate.jsonl',
);
```

Create the directory once before running the program. For a `www-data`
deployment, for example:

```sh
sudo install -d -o www-data -g www-data -m 0750 /home/shared_cgi/var/worker-gate
sudo install -o www-data -g www-data -m 0640 /dev/null /home/shared_cgi/var/worker-gate.jsonl
```

The paths must be absolute. The first program creates `gate-config.json` in the
lock directory. Later programs reject a different `max_workers` or `log_file`
instead of silently forming an incoherent gate or split audit trail.

To change capacity without editing every caller, set `WORKER_GATE_MAX_WORKERS`
once in the shared service/cron/CGI environment. It overrides legacy per-caller
values, updates `gate-config.json` when the gate is idle, and refuses to change
the setting while workers or waiters are active. Stop old masters, let workers
drain, then restart them with the new environment value.

For example, changing the deployment from 30 to 50 workers is one environment
change:

```sh
export WORKER_GATE_MAX_WORKERS=50
```

In systemd, cron, Apache/FastCGI, or the process supervisor, set that variable
in the shared service environment so every master inherits it.

### Crontab example

Edit the crontab:

```sh
crontab -e
```

Put the variable assignment near the top of that crontab. In a crontab it is a
plain assignment—do not write `export`:

```cron
SHELL=/bin/sh
PATH=/usr/bin:/bin
WORKER_GATE_MAX_WORKERS=50

# Use absolute paths; cron does not load your interactive shell profile.
*/5 * * * * /usr/bin/perl -I/home/shared_cgi/lib /home/shared_cgi/bin/multi_store_order_process_amazon.cgi >>/home/shared_cgi/var/amazon.cron.log 2>&1
*/5 * * * * /usr/bin/perl -I/home/shared_cgi/lib /home/shared_cgi/bin/multi_store_update_process_ebay.cgi >>/home/shared_cgi/var/ebay.cron.log 2>&1
```

The variable line applies to every job in that crontab, so Amazon, eBay, and
storefront masters all use the same 50-worker limit. If you use `/etc/cron.d`
instead of a user crontab, add the username field to each job line:

```cron
WORKER_GATE_MAX_WORKERS=50
*/5 * * * * www-data /usr/bin/perl -I/home/shared_cgi/lib /home/shared_cgi/bin/multi_store_order_process_amazon.cgi
```

After changing the value, stop the old cron-launched masters, let their workers
drain, and allow the new jobs to start. WorkerGate will update the shared
`gate-config.json` only when the gate is idle.

## See what is running

Install the included status command:

```sh
sudo install -m 0755 bin/worker-gate-status /usr/local/bin/worker-gate-status
```

Show one snapshot or refresh continuously:

```sh
worker-gate-status
worker-gate-status --watch
```

If you configured a different lock directory, pass it. The dashboard reads the
worker count from `gate-config.json` and rejects a mismatched explicit count:

```sh
worker-gate-status \
  --lock-dir /home/shared_cgi/var/worker-gate \
  --watch
```

Press `Ctrl-C` to stop watching.

## Timeouts and hardening options

By default `launch()` preserves the original behavior and can wait without a
time limit. To bound a stuck slot or starvation, pass a timeout in seconds:

```perl
$gate->launch(
    directory => $path,
    command   => ['/usr/bin/perl', "$path/order_process.cgi", 'amazon'],
    label     => "Amazon orders: $event",
    timeout   => 300,
);
```

A timed-out launch does not fork. It removes its live queue marker, logs
`TIMED_OUT`, and throws an exception. Constructor hardening options are:

- `log_lock_timeout` — maximum audit-lock wait, default `0.25` seconds.
- `control_lock_timeout` — maximum configuration-lock wait, default 2 seconds.
- `stale_file_age` — age before unlocked abandoned artifacts may be reclaimed,
  default one day.
- `file_mode` and `dir_mode` — creation modes, default `0640` and `0750`.

## System-wide installation (alternative)

If you prefer a normal Perl installation instead of `/home/shared_cgi/lib`:

```sh
perl Makefile.PL
make
make test
sudo make install
```

Then application code only needs `use WorkerGate;`; remove the
`use lib '/home/shared_cgi/lib';` line.

## Troubleshooting

- **`Can't locate WorkerGate.pm in @INC`**: install the file at
  `/home/shared_cgi/lib/WorkerGate.pm` and keep
  `use lib '/home/shared_cgi/lib';` before `use WorkerGate;`.
- **`Permission denied` for the lock directory or log**: repeat the one-time
  runtime setup with the actual Unix account that executes the script.
- **A job exits with code 126**: its `directory` does not exist or cannot be
  entered.
- **A job exits with code 127**: the executable in the first element of
  `command` does not exist or cannot be executed.
- **Jobs never exceed 30 but some appear to wait**: that is the gate working;
  a waiting job starts when a running job releases a slot.

## Operational notes

- Slot locks are the authority for current running capacity. Queue locks are
  the authority for currently waiting jobs.
- The JSONL log records `QUEUED`, `STARTED`, `FINISHED`, and explicit failure
  or unknown events. It is an audit trail, not the source of current status.
- A logging failure warns but does not prevent a worker from running. Monitor
  the log path separately if a complete audit trail is mandatory.
- Logging lock contention is bounded, so a paused logger cannot freeze worker
  scheduling indefinitely.
- Waiting is opportunistic rather than FIFO. A blocking `launch()` represents
  one current waiting job per master, not every future item in its input loop.
- The status command deduplicates jobs transitioning from queued to reserved,
  but it scans locks sequentially and therefore presents a near-instantaneous,
  not globally atomic, snapshot.
- An existing `SIGCHLD` reaper may consume status first. WorkerGate records
  `FINISHED_UNKNOWN` rather than inventing an exit code.
- If the master dies, workers that have already started keep their slots until
  they exit. The dead master cannot write their final lifecycle event, but the
  status command still reads the kernel locks correctly.
- The slot file descriptor intentionally survives `exec`. A worker that
  daemonizes or starts a long-lived descendant may therefore hold its slot
  longer than expected.
- When upgrading from a version without `gate-config.json`, stop all old
  masters before starting the first new one. Running old code cannot
  participate in the configuration check.

## Test a source checkout

```sh
perl Makefile.PL
make test
```
