#!usr/bin/perl
use strict;
use warnings;

use Config;
use Module::Build;
use inc::MyBuilder;

my $requires = {
    'Carp' => 0,
    'Config::General' => 0,
    'File::Copy' => 0,
    'File::Copy::Recursive' => 0,
    'File::Path' => 0,
};

my $build =  inc::MyBuilder->new(
    module_name        => 'LINZ::PNZPP',
    license            => 'bsd',
    dist_author        => 'LINZ',
    dist_version_from  => 'lib/LINZ/PNZPP.pm',
    dist_abstract      => 'Installs the PositioNZ-PP server',
    requires           => $requires,
    create_makefile_pl => 'small',
);

$build->add_build_element('conf');

$build->create_build_script;
