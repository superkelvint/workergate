use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'WorkerGate',
    VERSION_FROM  => 'lib/WorkerGate.pm',
    ABSTRACT_FROM => 'lib/WorkerGate.pm',
    AUTHOR        => 'WorkerGate contributors',
    LICENSE       => 'perl_5',
    EXE_FILES     => ['bin/worker-gate-status'],
    PREREQ_PM     => {
        'Fcntl'         => 0,
        'File::Path'    => 0,
        'File::Spec'    => 0,
        'File::Temp'    => 0,
        'Getopt::Long'  => 0,
        'JSON::PP'      => 0,
        'POSIX'         => 0,
        'Time::HiRes'   => 0,
    },
    TEST_REQUIRES => {
        'File::Temp'    => 0,
        'Test::More'    => 0,
    },
);
