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

sub properties {
    return {
        nasty_api_host => {
            description => 'Nasty appliance hostname or IP',
            type        => 'string',
        },
        nasty_api_port => {
            description => 'Nasty WebSocket port',
            type        => 'integer',
            default     => 443,
        },
        nasty_api_scheme => {
            description => 'wss or ws',
            type        => 'string',
            default     => 'wss',
        },
        nasty_api_token => {
            description => 'API token (Bearer auth)',
            type        => 'string',
        },
        nasty_api_verify_ssl => {
            description => 'Verify TLS certificate (1=yes, 0=no)',
            type        => 'boolean',
            default     => 1,
        },
        nasty_filesystem => {
            description => 'bcachefs filesystem name on Nasty',
            type        => 'string',
        },
        nasty_subvolume_prefix => {
            description => 'Parent subvolume prefix for all VM disks (e.g. pve)',
            type        => 'string',
        },
        nasty_transport_mode => {
            description => 'Transport: iscsi or nvme-tcp',
            type        => 'string',
            default     => 'iscsi',
        },
        nasty_iscsi_target => {
            description => 'Preconfigured iSCSI target IQN on Nasty',
            type        => 'string',
        },
        nasty_nvme_subsystem => {
            description => 'Preconfigured NVMe-oF subsystem name on Nasty',
            type        => 'string',
        },
        nasty_nvme_hostnqn => {
            description => 'Host NQN (auto-detected if not set)',
            type        => 'string',
        },
        nasty_log_level => {
            description => 'Syslog verbosity: 0=err 1=info 2=debug',
            type        => 'integer',
            default     => 1,
        },
    };
}

sub options {
    return {
        path              => { optional => 1 },
        nodes             => { optional => 1 },
        disable           => { optional => 1 },
        content           => { optional => 1 },
        nasty_api_host        => { fixed => 1 },
        nasty_api_port        => { optional => 1 },
        nasty_api_scheme      => { optional => 1 },
        nasty_api_token       => {},
        nasty_api_verify_ssl  => { optional => 1 },
        nasty_filesystem      => { fixed => 1 },
        nasty_subvolume_prefix => { fixed => 1 },
        nasty_transport_mode  => { fixed => 1 },
        nasty_iscsi_target    => { optional => 1 },
        nasty_nvme_subsystem  => { optional => 1 },
        nasty_nvme_hostnqn    => { optional => 1 },
        nasty_log_level       => { optional => 1 },
    };
}

sub check_config {
    my ($class, $storeid, $scfg, $create, $skipsmountpointcheck) = @_;

    die "nasty_api_host is required\n"        unless $scfg->{nasty_api_host};
    die "nasty_api_token is required\n"       unless $scfg->{nasty_api_token};
    die "nasty_filesystem is required\n"      unless $scfg->{nasty_filesystem};
    die "nasty_subvolume_prefix is required\n" unless $scfg->{nasty_subvolume_prefix};

    my $mode = $scfg->{nasty_transport_mode} // 'iscsi';
    die "nasty_transport_mode must be 'iscsi' or 'nvme-tcp'\n"
        unless $mode eq 'iscsi' || $mode eq 'nvme-tcp';

    if ($mode eq 'iscsi') {
        die "nasty_iscsi_target is required when transport is iscsi\n"
            unless $scfg->{nasty_iscsi_target};
    } else {
        die "nasty_nvme_subsystem is required when transport is nvme-tcp\n"
            unless $scfg->{nasty_nvme_subsystem};
    }

    return $class->SUPER::check_config($storeid, $scfg, $create, $skipsmountpointcheck);
}

sub parse_volname {
    my ($class, $volname) = @_;

    # pve/vm-100-disk-0
    # pve/vm-100-state-snapname
    # pve/pve-snapclone-vm-100-disk-0-snapname
    if ($volname =~ m!^([^/]+)/vm-(\d+)-(\S+)$!) {
        my ($prefix, $vmid, $rest) = ($1, $2, $3);
        my $name = "$prefix/vm-$vmid-$rest";
        return ('images', $name, $vmid, undef, undef, 0, 'raw');
    }

    die "unable to parse volume name '$volname'\n";
}

1;

