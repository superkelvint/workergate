use strict;
use warnings;

use Test::More;

BEGIN { use_ok('WorkerGate') }

ok(WorkerGate->can('launch'), 'launch API exists');
ok(WorkerGate->can('wait_all'), 'wait_all API exists');
ok(WorkerGate->can('active_children'), 'active_children API exists');

done_testing;
