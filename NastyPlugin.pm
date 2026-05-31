# NastyPlugin.pm
package PVE::Storage::Custom::NastyPlugin;

use strict;
use warnings;
use base qw(PVE::Storage::Plugin);

use IO::Socket::SSL;
use IO::Select;
use JSON::XS;
use MIME::Base64;
use Sys::Syslog qw(openlog syslog);
use Digest::SHA qw(sha1);
use POSIX qw(floor);

openlog('nastyplugin', 'pid', 'daemon');

my $JSON = JSON::XS->new->utf8->allow_nonref;

# WebSocket connection cache: "$host:$port" => { sock, id_counter }
my %WS_CONN;

# API response cache: "$host:$method" => { result, expires }
my %API_CACHE;

# Cache TTLs in seconds
my %CACHE_TTL = (
    'subvolume.list'      => 60,
    'share.iscsi.list'    => 60,
    'share.nvmeof.list'   => 60,
    'system.info'         => 300,
);

# Methods that invalidate cache keys on success
my %CACHE_INVALIDATE = (
    'subvolume.create'        => ['subvolume.list'],
    'subvolume.delete'        => ['subvolume.list'],
    'subvolume.resize'        => ['subvolume.list'],
    'snapshot.create'         => [],
    'snapshot.delete'         => [],
    'snapshot.clone'          => ['subvolume.list'],
    'share.iscsi.add_lun'     => ['share.iscsi.list'],
    'share.iscsi.remove_lun'  => ['share.iscsi.list'],
    'share.nvmeof.add_namespace'    => ['share.nvmeof.list'],
    'share.nvmeof.remove_namespace' => ['share.nvmeof.list'],
);

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

sub _log {
    my ($scfg, $level, $msg) = @_;
    my $configured = $scfg->{nasty_log_level} // 1;
    return if $level > $configured;
    my $priority = $level == 0 ? 'err' : $level == 1 ? 'info' : 'debug';
    syslog($priority, '%s', $msg);
}

sub _ws_key {
    my $raw = '';
    $raw .= chr(int(rand(256))) for 1..16;
    return encode_base64($raw, '');
}

sub _ws_connect {
    my ($scfg) = @_;

    my $host    = $scfg->{nasty_api_host};
    my $port    = $scfg->{nasty_api_port}   // 443;
    my $scheme  = $scfg->{nasty_api_scheme} // 'wss';
    my $token   = $scfg->{nasty_api_token};
    my $verify  = $scfg->{nasty_api_verify_ssl} // 1;

    my $sock;
    if ($scheme eq 'wss') {
        $sock = IO::Socket::SSL->new(
            PeerHost        => $host,
            PeerPort        => $port,
            SSL_verify_mode => $verify ? IO::Socket::SSL::SSL_VERIFY_PEER()
                                       : IO::Socket::SSL::SSL_VERIFY_NONE(),
        ) or die "[Nasty] TLS connection to $host:$port failed: "
                 . IO::Socket::SSL::errstr() . "\n"
                 . ($verify ? "  set nasty_api_verify_ssl=0 to disable certificate verification\n" : "");
    } else {
        require IO::Socket::INET;
        $sock = IO::Socket::INET->new(
            PeerHost => $host,
            PeerPort => $port,
            Proto    => 'tcp',
        ) or die "[Nasty] connection to $host:$port failed: $!\n";
    }

    # HTTP upgrade handshake
    my $ws_key = _ws_key();
    my $req = join("\r\n",
        "GET /ws HTTP/1.1",
        "Host: $host:$port",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: $ws_key",
        "Sec-WebSocket-Version: 13",
        "Authorization: Bearer $token",
        "", "",
    );
    print $sock $req;

    # Read response headers (10s timeout)
    my $sel = IO::Select->new($sock);
    my $response = '';
    while (1) {
        unless ($sel->can_read(10)) {
            die "[Nasty] WebSocket upgrade timed out after 10s\n";
        }
        my $line;
        $sock->read($line, 1) or die "[Nasty] WebSocket upgrade: connection closed\n";
        $response .= $line;
        last if $response =~ /\r\n\r\n$/;
    }
    die "[Nasty] WebSocket upgrade failed: $response\n"
        unless $response =~ /^HTTP\/1\.1 101/;

    # Verify Sec-WebSocket-Accept (RFC 6455 §4.1)
    my $expected_accept = encode_base64(
        sha1($ws_key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), ''
    );
    $expected_accept =~ s/\s+$//;  # trim trailing whitespace/newline
    if ($response =~ /Sec-WebSocket-Accept:\s*(\S+)/i) {
        my $got = $1;
        die "[Nasty] WebSocket accept header mismatch (MITM?)\n"
            unless $got eq $expected_accept;
    } else {
        die "[Nasty] WebSocket response missing Sec-WebSocket-Accept header\n";
    }

    return $sock;
}

sub _ws_ensure_connected {
    my ($scfg) = @_;
    my $host = $scfg->{nasty_api_host};
    my $port = $scfg->{nasty_api_port} // 443;
    my $key  = "$host:$port";

    if (my $conn = $WS_CONN{$key}) {
        return $conn if $conn->{sock}->connected;
        delete $WS_CONN{$key};
    }

    my $sock = _ws_connect($scfg);
    $WS_CONN{$key} = { sock => $sock, id => 1 };
    return $WS_CONN{$key};
}

sub _ws_send_frame {
    my ($sock, $text) = @_;
    my $payload = $text;
    my $len     = length($payload);

    # Masking key (4 random bytes)
    my $mask = pack('C4', map { int(rand(256)) } 1..4);
    my $masked = '';
    for my $i (0 .. $len - 1) {
        $masked .= chr(ord(substr($payload, $i, 1)) ^ ord(substr($mask, $i % 4, 1)));
    }

    my $header;
    if ($len <= 125) {
        $header = pack('CC', 0x81, 0x80 | $len);
    } elsif ($len <= 65535) {
        $header = pack('CCn', 0x81, 0x80 | 126, $len);
    } else {
        $header = pack('CCN', 0x81, 0x80 | 127, 0) . pack('N', $len);
    }

    print $sock $header . $mask . $masked;
}

sub _ws_recv_frame {
    my ($sock) = @_;

    for my $attempt (1..50) {
        # Read 2-byte header
        my $hdr = '';
        $sock->read($hdr, 2) == 2 or die "[Nasty] WebSocket read error: connection closed\n";
        my ($b0, $b1) = unpack('CC', $hdr);

        my $opcode = $b0 & 0x0f;
        my $len    = $b1 & 0x7f;

        if ($len == 126) {
            my $ext; $sock->read($ext, 2); $len = unpack('n', $ext);
        } elsif ($len == 127) {
            my $ext; $sock->read($ext, 8);
            my ($hi, $lo) = unpack('NN', $ext);
            $len = ($hi << 32) | $lo;
        }

        # Server frames are unmasked
        my $payload = '';
        while (length($payload) < $len) {
            my $chunk;
            my $n = $sock->read($chunk, $len - length($payload));
            die "[Nasty] WebSocket read error\n" unless $n;
            $payload .= $chunk;
        }

        return $payload if $opcode == 1;   # text frame
        die "[Nasty] WebSocket connection closed by server\n" if $opcode == 8;  # close
        # opcode 0, 9, 10 (continuation, ping, pong) — skip and read next frame
    }
    die "[Nasty] WebSocket: too many non-text frames\n";
}

sub _api_call {
    my ($scfg, $method, $params) = @_;
    $params //= {};

    my $host = $scfg->{nasty_api_host};
    my $port = $scfg->{nasty_api_port} // 443;

    # Check cache for read-only methods
    if (exists $CACHE_TTL{$method}) {
        my $ckey = "$host:$method";
        if (my $cached = $API_CACHE{$ckey}) {
            if (time() < $cached->{expires}) {
                _log($scfg, 2, "[Nasty] cache hit: $method");
                return $cached->{result};
            }
        }
    }

    my $conn = eval { _ws_ensure_connected($scfg) };
    if ($@) {
        die $@;
    }

    my $id      = $conn->{id}++;
    my $request = $JSON->encode({
        jsonrpc => '2.0',
        id      => $id,
        method  => $method,
        params  => $params,
    });

    _log($scfg, 2, "[Nasty] -> $method");

    eval { _ws_send_frame($conn->{sock}, $request) };
    if ($@) {
        delete $WS_CONN{"$host:$port"};
        die "[Nasty] $method failed: send error: $@\n";
    }

    my $raw = eval { _ws_recv_frame($conn->{sock}) };
    if ($@) {
        delete $WS_CONN{"$host:$port"};
        die "[Nasty] $method failed: recv error: $@\n";
    }

    my $response = $JSON->decode($raw);
    if (defined $response->{id} && $response->{id} != $id) {
        die "[Nasty] $method: response ID mismatch (got $response->{id}, expected $id)\n";
    }
    if (my $err = $response->{error}) {
        die "[Nasty] $method failed: " . ($err->{message} // 'unknown error') . "\n";
    }

    my $result = $response->{result};

    # Cache read-only responses
    if (exists $CACHE_TTL{$method}) {
        my $ckey = "$host:$method";
        $API_CACHE{$ckey} = { result => $result, expires => time() + $CACHE_TTL{$method} };
    }

    # Invalidate related cache keys on writes
    if (my $inv = $CACHE_INVALIDATE{$method}) {
        for my $k (@$inv) {
            delete $API_CACHE{"$host:$k"};
        }
    }

    return $result;
}

# Returns lun_id or undef if not found.
sub _iscsi_find_lun {
    my ($scfg, $block_device) = @_;
    my $targets = _api_call($scfg, 'share.iscsi.list');
    my $target_iqn = $scfg->{nasty_iscsi_target};
    for my $t (@$targets) {
        next unless $t->{iqn} eq $target_iqn;
        for my $lun (@{ $t->{luns} // [] }) {
            return $lun->{lun_id} if $lun->{backstore_path} eq $block_device;
        }
    }
    return undef;
}

sub _iscsi_target_id {
    my ($scfg) = @_;
    my $targets = _api_call($scfg, 'share.iscsi.list');
    my $target_iqn = $scfg->{nasty_iscsi_target};
    for my $t (@$targets) {
        return $t->{id} if $t->{iqn} eq $target_iqn;
    }
    die "[Nasty] iSCSI target '$target_iqn' not found on Nasty\n";
}

sub _iscsi_login {
    my ($scfg) = @_;
    my $iqn  = $scfg->{nasty_iscsi_target};
    my $host = $scfg->{nasty_api_host};
    _log($scfg, 1, "[Nasty] iSCSI login: target=$iqn portal=$host");
    system('iscsiadm', '-m', 'discovery', '-t', 'sendtargets', '-p', $host) == 0
        or warn "[Nasty] iSCSI discovery failed (continuing)\n";
    system('iscsiadm', '-m', 'node', '-T', $iqn, '-p', $host, '--login') == 0
        or die "[Nasty] iSCSI login failed for target $iqn\n";
    sleep(2);  # wait for udev to create device nodes
}

sub _iscsi_rescan {
    my ($scfg, $lun_id) = @_;
    my $iqn = $scfg->{nasty_iscsi_target};
    system('iscsiadm', '-m', 'session', '--rescan') == 0
        or warn "[Nasty] iSCSI rescan returned non-zero (continuing)\n";
    sleep(1);
    # Find device via /dev/disk/by-path
    my $by_path = "/dev/disk/by-path";
    opendir(my $dh, $by_path) or return undef;
    my @links = grep { /iscsi-$iqn.*lun-$lun_id$/ } readdir($dh);
    closedir($dh);
    return undef unless @links;
    return readlink("$by_path/$links[0]")
        ? "$by_path/$links[0]"
        : undef;
}

# Returns nsid or undef if not found.
sub _nvme_find_ns {
    my ($scfg, $block_device) = @_;
    my $subsystems = _api_call($scfg, 'share.nvmeof.list');
    my $target_name = $scfg->{nasty_nvme_subsystem};
    for my $s (@$subsystems) {
        next unless ($s->{nqn} // '') =~ /\Q$target_name\E/ || ($s->{id} // '') eq $target_name;
        for my $ns (@{ $s->{namespaces} // [] }) {
            return $ns->{nsid} if $ns->{device_path} eq $block_device;
        }
    }
    return undef;
}

sub _nvme_subsystem_id {
    my ($scfg) = @_;
    my $subsystems = _api_call($scfg, 'share.nvmeof.list');
    my $target_name = $scfg->{nasty_nvme_subsystem};
    for my $s (@$subsystems) {
        return $s->{id}
            if ($s->{nqn} // '') =~ /\Q$target_name\E/
            || ($s->{id} // '') eq $target_name;
    }
    die "[Nasty] NVMe-oF subsystem '$target_name' not found on Nasty\n";
}

sub _nvme_connect {
    my ($scfg) = @_;
    my $subsystems = _api_call($scfg, 'share.nvmeof.list');
    my $target_name = $scfg->{nasty_nvme_subsystem};
    my ($subsys) = grep {
        ($_->{nqn} // '') =~ /\Q$target_name\E/ || ($_->{id} // '') eq $target_name
    } @$subsystems;
    die "[Nasty] NVMe-oF subsystem '$target_name' not found\n" unless $subsys;

    my $nqn  = $subsys->{nqn};
    my $host = $scfg->{nasty_api_host};
    my $port = 4420;
    if (my $p = $subsys->{ports} && $subsys->{ports}[0]) {
        $port = $p->{service_id} // 4420;
    }

    my $hostnqn = $scfg->{nasty_nvme_hostnqn};
    unless ($hostnqn) {
        open(my $fh, '<', '/etc/nvme/hostnqn') or die "[Nasty] cannot read /etc/nvme/hostnqn: $!\n";
        $hostnqn = do { local $/; <$fh> };
        chomp $hostnqn;
        close $fh;
    }

    _log($scfg, 1, "[Nasty] NVMe connect: nqn=$nqn host=$host:$port");
    system('nvme', 'connect', '-t', 'tcp', '-n', $nqn, '-a', $host, '-s', $port,
           '--hostnqn', $hostnqn) == 0
        or die "[Nasty] nvme connect failed for $nqn\n";
    sleep(2);
}

sub _nvme_rescan {
    my ($scfg, $device_path) = @_;
    # device_path is a loop device like /dev/loop3
    # After nvme connect, the namespace appears as /dev/nvmeXnY
    # Find it by scanning nvme subsystem controllers
    sleep(1);
    my @devs = glob('/dev/nvme*n*');
    for my $dev (@devs) {
        next unless $dev =~ m!/dev/nvme\d+n\d+$!;
        # Check if the backing device matches via sysfs
        my $nsdev = $dev;
        $nsdev =~ s!/dev/!!;
        my $sysfs = "/sys/class/block/$nsdev/device";
        next unless -e $sysfs;
        return $dev;
    }
    return undef;
}

sub _add_to_share {
    my ($scfg, $block_device) = @_;
    my $mode = $scfg->{nasty_transport_mode} // 'iscsi';
    if ($mode eq 'iscsi') {
        my $tid = _iscsi_target_id($scfg);
        return _api_call($scfg, 'share.iscsi.add_lun', {
            target_id    => $tid,
            backstore_path => $block_device,
        });
    } else {
        my $sid = _nvme_subsystem_id($scfg);
        return _api_call($scfg, 'share.nvmeof.add_namespace', {
            subsystem_id => $sid,
            device_path  => $block_device,
        });
    }
}

sub _remove_from_share {
    my ($scfg, $block_device) = @_;
    my $mode = $scfg->{nasty_transport_mode} // 'iscsi';
    if ($mode eq 'iscsi') {
        my $lun_id = _iscsi_find_lun($scfg, $block_device);
        return unless defined $lun_id;
        my $tid = _iscsi_target_id($scfg);
        _api_call($scfg, 'share.iscsi.remove_lun', {
            target_id => $tid,
            lun_id    => $lun_id,
        });
    } else {
        my $nsid = _nvme_find_ns($scfg, $block_device);
        return unless defined $nsid;
        my $sid = _nvme_subsystem_id($scfg);
        _api_call($scfg, 'share.nvmeof.remove_namespace', {
            subsystem_id => $sid,
            nsid         => $nsid,
        });
    }
}

1;

