# NastyPlugin.pm
package PVE::Storage::Custom::NastyPlugin;

use strict;
use warnings;
use base qw(PVE::Storage::Plugin);

our $VERSION = '0.1.0';

sub type { return 'nastyplugin'; }

sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1 }, { images => 1 }],
        format  => [{ raw => 1 }, 'raw'],
        select_existing => 1,
        shared => 1,
    };
}

1;
