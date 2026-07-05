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
use Digest::SHA qw(sha1 sha1_hex);
use POSIX qw(floor);

openlog('nastyplugin', 'pid', 'daemon');

my $JSON = JSON::XS->new->utf8->allow_nonref;

# WebSocket connection cache: "$host:$port" => { sock, id_counter }
my %WS_CONN;

# API response cache: "$host:$method" => { result, expires }
my %API_CACHE;

# Cache TTLs in seconds
my %CACHE_TTL = (
    'share.iscsi.list'    => 60,
    'share.nvmeof.list'   => 60,
    'system.info'         => 300,
    'snapshot.list'       => 10,
);

# Methods that invalidate cache keys on success
my %CACHE_INVALIDATE = (
    'subvolume.create'        => ['subvolume.list'],
    'subvolume.delete'        => ['subvolume.list'],
    'subvolume.resize'        => ['subvolume.list'],
    'snapshot.create'         => ['snapshot.list'],
    'snapshot.delete'         => ['snapshot.list'],
    'snapshot.clone'          => ['subvolume.list'],
    'share.iscsi.add_lun'     => ['share.iscsi.list'],
    'share.iscsi.remove_lun'  => ['share.iscsi.list'],
    'share.nvmeof.add_namespace'    => ['share.nvmeof.list'],
    'share.nvmeof.remove_namespace' => ['share.nvmeof.list'],
);

our $VERSION = '0.1.10';

sub api {
    my $tested_apiver = 14;

    my $system_apiver = eval { require PVE::Storage; PVE::Storage::APIVER() } // 11;
    my $system_apiage = eval { PVE::Storage::APIAGE() } // 2;

    if ($system_apiver >= 11 && $system_apiver <= $tested_apiver) {
        return $system_apiver;
    }
    if ($system_apiver - $system_apiage < $tested_apiver) {
        return $tested_apiver;
    }
    return 11;
}

sub type { return 'nastyplugin'; }

sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1 }, { images => 1 }],
        format  => [{ raw => 1 }, 'raw'],
        select_existing => 1,
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
        shared            => { optional => 1 },
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

sub _untaint_abs_path {
    my ($path) = @_;
    die "[Nasty] invalid device path\n" unless defined($path) && $path =~ m!^(/[-A-Za-z0-9_./:@+=]+)$!;
    return $1;
}

sub _quiet_system {
    my (@cmd) = @_;

    open(my $oldout, '>&', \*STDOUT) or die "[Nasty] failed to dup stdout: $!\n";
    open(my $olderr, '>&', \*STDERR) or die "[Nasty] failed to dup stderr: $!\n";
    open(STDOUT, '>', '/dev/null') or die "[Nasty] failed to redirect stdout: $!\n";
    open(STDERR, '>', '/dev/null') or die "[Nasty] failed to redirect stderr: $!\n";

    my $ret = system(@cmd);

    open(STDOUT, '>&', $oldout) or die "[Nasty] failed to restore stdout: $!\n";
    open(STDERR, '>&', $olderr) or die "[Nasty] failed to restore stderr: $!\n";

    return $ret;
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
    # Drain the server's initial auth broadcast before any RPC calls
    _ws_recv_frame($sock);
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

    # Retry once on connection errors (e.g., stale socket after forked child exits).
    # A short backoff between attempts avoids hammering the API during transient
    # network blips and gives the kernel time to recycle the socket.
    my $last_err;
    for my $retry (1..2) {
        if ($retry > 1) {
            select(undef, undef, undef, 0.1);  # 100ms backoff
        }
        my $conn = eval { _ws_ensure_connected($scfg) };
        if ($@) {
            $last_err = $@;
            next;
        }

        my $id      = $conn->{id}++;
        my $request = $JSON->encode({
            jsonrpc => '2.0',
            id      => $id,
            method  => $method,
            params  => $params,
        });

        _log($scfg, 2, "[Nasty] -> $method params=" . ($JSON->encode($params)));

        my $send_err;
        eval { _ws_send_frame($conn->{sock}, $request) };
        if ($@) {
            delete $WS_CONN{"$host:$port"};
            $last_err = "[Nasty] $method failed: send error: $@\n";
            next;
        }

        my $response;
        my $recv_err;
        for my $attempt (1..50) {
            my $raw = eval { _ws_recv_frame($conn->{sock}) };
            if ($@) {
                delete $WS_CONN{"$host:$port"};
                $recv_err = $@;
                last;
            }

            _log($scfg, 2, "[Nasty] <- raw=$raw");
            $response = $JSON->decode($raw);
            next if !defined $response->{id};
            next if $response->{id} != $id;
            last;
        }

        if ($recv_err) {
            $last_err = "[Nasty] $method failed: recv error: $recv_err\n";
            next;  # retry
        }

        die "[Nasty] $method: response ID mismatch or missing response (expected $id)\n"
            unless $response && defined $response->{id} && $response->{id} == $id;

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

    die $last_err // "[Nasty] $method: failed after retries\n";
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
    _quiet_system('iscsiadm', '-m', 'discovery', '-t', 'sendtargets', '-p', $host) == 0
        or warn "[Nasty] iSCSI discovery failed (continuing)\n";
    my $ret = _quiet_system('iscsiadm', '-m', 'node', '-T', $iqn, '-p', $host, '--login');
    my $exit_code = $ret >> 8;
    die "[Nasty] iSCSI login failed for target $iqn (exit $exit_code)\n"
        unless $exit_code == 0 || $exit_code == 15;  # 15 = ISCSI_ERR_SESS_EXISTS
    sleep(2);  # wait for udev to create device nodes
}

sub _iscsi_rescan {
    my ($scfg, $lun_id) = @_;
    my $iqn = $scfg->{nasty_iscsi_target};
    _quiet_system('iscsiadm', '-m', 'session', '--rescan') == 0
        or warn "[Nasty] iSCSI rescan returned non-zero (continuing)\n";
    sleep(1);
    # Find device via /dev/disk/by-path
    my $by_path = "/dev/disk/by-path";
    opendir(my $dh, $by_path) or return undef;
    my @links = grep { /iscsi-\Q$iqn\E.*lun-\Q$lun_id\E$/ } readdir($dh);
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

sub _nvme_find_ctrl_idx {
    my ($target_nqn) = @_;

    for my $ctl_dir (glob('/sys/class/nvme-fabrics/ctl/nvme*')) {
        my $nqn_file = "$ctl_dir/subsysnqn";
        next unless -f $nqn_file;
        open(my $fh, '<', $nqn_file) or next;
        my $nqn = do { local $/; <$fh> };
        close($fh);
        chomp $nqn;
        next unless $nqn eq $target_nqn || $nqn =~ /\Q$target_nqn\E/;
        my ($ctrl_idx) = ($ctl_dir =~ m!/nvme(\d+)$!);
        return $ctrl_idx if defined $ctrl_idx;
    }

    return undef;
}

sub _nvme_hostid_for_hostnqn {
    my ($hostnqn) = @_;
    my $hex = sha1_hex('nastyplugin:' . ($hostnqn // ''));
    substr($hex, 12, 1) = '5';
    substr($hex, 16, 1) = sprintf('%x', (hex(substr($hex, 16, 1)) & 0x3) | 0x8);
    return join('-', substr($hex, 0, 8), substr($hex, 8, 4), substr($hex, 12, 4), substr($hex, 16, 4), substr($hex, 20, 12));
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
    return 1 if defined _nvme_find_ctrl_idx($nqn);

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

    my $hostid = _nvme_hostid_for_hostnqn($hostnqn);

    _log($scfg, 1, "[Nasty] NVMe connect: nqn=$nqn host=$host:$port");
    my $ret = system('nvme', 'connect', '-t', 'tcp', '-n', $nqn, '-a', $host, '-s', $port,
                     '--hostnqn', $hostnqn, '--hostid', $hostid);
    my $exit_code = $ret >> 8;
    die "[Nasty] nvme connect failed for $nqn (exit $exit_code)\n"
        unless $exit_code == 0 || $exit_code == 70;
    sleep(2);
}

# Find the /dev/nvmeXnY path for a given NASty NSID.
# Locates the NVMe controller connected to our target NQN, then returns
# /dev/nvme<ctrl>n<nsid> after waiting for udev to expose the block node.
sub _nvme_find_dev_by_nsid {
    my ($scfg, $nsid) = @_;

    my $target_nqn = $scfg->{nasty_nvme_subsystem};
    my $ctrl_idx = _nvme_find_ctrl_idx($target_nqn);
    return undef unless defined $ctrl_idx;

    # Wait up to 10s for /dev/nvme<ctrl>n<nsid> to appear
    my $dev = "/dev/nvme${ctrl_idx}n${nsid}";
    for my $attempt (1..20) {
        return $dev if -b $dev;
        select(undef, undef, undef, 0.5);  # 500ms
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
    } elsif ($mode eq 'nvme-tcp') {
        my $sid = _nvme_subsystem_id($scfg);
        return _api_call($scfg, 'share.nvmeof.add_namespace', {
            subsystem_id => $sid,
            device_path  => $block_device,
        });
    } else {
        die "[Nasty] unknown transport mode '$mode'\n";
    }
}

sub _iscsi_remove_scsi_device {
    my ($scfg, $lun_id) = @_;
    my $iqn     = $scfg->{nasty_iscsi_target};
    my $by_path = "/dev/disk/by-path";
    opendir(my $dh, $by_path) or return;
    my @links = grep { /iscsi-\Q$iqn\E.*lun-\Q$lun_id\E$/ } readdir($dh);
    closedir($dh);
    for my $link (@links) {
        my $target = readlink("$by_path/$link") or next;
        # $target is like ../../sdX — extract device name (untaint for taint mode)
        my ($dev) = ($target =~ m!([A-Za-z0-9_-]+)$!) or next;
        my $delete_path = "/sys/block/$dev/device/delete";
        if (-e $delete_path) {
            _log($scfg, 2, "[Nasty] removing stale SCSI device $dev (LUN $lun_id)");
            open(my $fh, '>', $delete_path) or next;
            print $fh "1\n";
            close($fh);
        }
    }
}

sub _remove_from_share {
    my ($scfg, $block_device) = @_;
    my $mode = $scfg->{nasty_transport_mode} // 'iscsi';
    if ($mode eq 'iscsi') {
        my $lun_id = _iscsi_find_lun($scfg, $block_device);
        return unless defined $lun_id;
        my $tid = _iscsi_target_id($scfg);
        # Remove LUN from target first so no new initiator commands are accepted,
        # then clean up the local SCSI device.  Reversing this order causes
        # TARGET_CORE to log NON_EXISTENT_LUN for in-flight initiator retries.
        _api_call($scfg, 'share.iscsi.remove_lun', {
            target_id => $tid,
            lun_id    => $lun_id,
        });
        _iscsi_remove_scsi_device($scfg, $lun_id);
    } elsif ($mode eq 'nvme-tcp') {
        my $nsid = _nvme_find_ns($scfg, $block_device);
        return unless defined $nsid;
        my $sid = _nvme_subsystem_id($scfg);
        _api_call($scfg, 'share.nvmeof.remove_namespace', {
            subsystem_id => $sid,
            nsid         => $nsid,
        });
    } else {
        die "[Nasty] unknown transport mode '$mode'\n";
    }
}

# ---------------------------------------------------------------------------
# PVE storage interface methods
# ---------------------------------------------------------------------------

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # 1. Verify API connectivity
    my $info = _api_call($scfg, 'system.info');
    _log($scfg, 1, "[Nasty] connected to Nasty $info->{version}");

    # 2. Verify target/subsystem exists
    my $mode = $scfg->{nasty_transport_mode} // 'iscsi';
    if ($mode eq 'iscsi') {
        _iscsi_target_id($scfg);  # dies if not found
    } else {
        _nvme_subsystem_id($scfg);  # dies if not found
    }

    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $usage = eval { _api_call($scfg, 'fs.usage', { name => $scfg->{nasty_filesystem} }) };
    if ($@) {
        warn "[Nasty] status failed: $@";
        return (0, 0, 0, 0);
    }

    # Sum across all devices
    my ($total, $free) = (0, 0);
    for my $dev (@{ $usage->{devices} // [] }) {
        $total += $dev->{total_bytes} // 0;
        $free  += $dev->{free_bytes}  // 0;
    }
    my $used = $total - $free;

    return ($total, $free, $used, 1);
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $fs     = $scfg->{nasty_filesystem};
    my $prefix = $scfg->{nasty_subvolume_prefix};

    my $subvols = eval { _api_call($scfg, 'subvolume.list', { filesystem => $fs }) };
    if ($@) {
        warn "[Nasty] list_images failed: $@";
        return [];
    }

    my %want = $vollist ? (map { $_ => 1 } @$vollist) : ();

    my @res;
    for my $sv (@$subvols) {
        my $name = $sv->{name};

        # Only manage volumes under our prefix
        next unless $name =~ m!^\Q$prefix\E/vm-(\d+)-!;
        my $svmid = $1;

        # Skip snapclones
        next if $name =~ m!^\Q$prefix\E/pve-snapclone-!;

        # Filter by vmid if requested
        next if defined $vmid && $svmid != $vmid;

        # Validate subvolume actually exists — NASty's subvolume.list may return
        # stale entries for recently-deleted subvolumes.  subvolume.get will fail
        # immediately if the subvolume is truly gone.
        my $sv_check = eval { _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $name }) };
        if ($@) {
            _log($scfg, 2, "[Nasty] list_images: skipping stale subvolume '$name'");
            next;
        }

        my $volname = $name;
        my $volid   = "$storeid:$volname";

        if ($vollist) {
            next unless $want{$volid};
        }

        push @res, {
            volid  => $volid,
            format => 'raw',
            size   => $sv_check->{volsize_bytes} // 0,
            vmid   => $svmid,
            content => 'images',
        };
    }

    return \@res;
}

sub _next_disk_num {
    my ($scfg, $vmid) = @_;
    my $fs     = $scfg->{nasty_filesystem};
    my $prefix = $scfg->{nasty_subvolume_prefix};
    my $subvols = eval { _api_call($scfg, 'subvolume.list', { filesystem => $fs }) };
    die "[Nasty] _next_disk_num: subvolume.list failed: $@" if $@;
    my $max = -1;
    for my $sv (@$subvols) {
        if ($sv->{name} =~ m!^\Q$prefix\E/vm-\Q$vmid\E-disk-(\d+)$!) {
            $max = $1 if $1 > $max;
        }
    }
    return $max + 1;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $fs     = $scfg->{nasty_filesystem};
    my $prefix = $scfg->{nasty_subvolume_prefix};

    # size is in KB from Proxmox
    my $bytes = $size * 1024;

    # Retry loop for concurrent allocation — the subvolume.create + transport expose
    # path is not atomic; two simultaneous callers can collide on the same backend LUN
    # or namespace slot. Backoff reduces the window of contention.
    my $max_retries = 3;
    my $err;
    for my $retry (1 .. $max_retries) {
        my $volname;
        if ($name) {
            # Proxmox passed an explicit name (e.g. for vmstate) — no retry needed
            $volname = "$prefix/$name";
        } else {
            my $n = _next_disk_num($scfg, $vmid);
            $volname = "$prefix/vm-$vmid-disk-$n";
        }

        _log($scfg, 1, "[Nasty] alloc_image: $volname ($bytes bytes) [try $retry/$max_retries]");

        my $sv;
        eval {
            $sv = _api_call($scfg, 'subvolume.create', {
                filesystem     => $fs,
                name           => $volname,
                subvolume_type => 'block',
                volsize_bytes  => 0 + $bytes,
            });
        };
        if ($@) {
            $err = $@;
            _log($scfg, 1, "[Nasty] alloc_image subvolume.create failed: $err");
            # Clean up orphaned subvolume before retrying
            eval { _api_call($scfg, 'subvolume.delete', { filesystem => $fs, name => $volname }) };
            last if $retry == $max_retries;
            select(undef, undef, undef, 0.5 * $retry);  # escalating backoff
            next;
        }

        my $block_device = $sv->{block_device}
            or do { $err = "subvolume.create returned no block_device for $volname"; eval { _api_call($scfg, 'subvolume.delete', { filesystem => $fs, name => $volname }) }; last; };

        eval {
            _add_to_share($scfg, $block_device);
        };
        if ($@) {
            $err = $@;
            _log($scfg, 1, "[Nasty] alloc_image _add_to_share failed: $err");
            # Clean up the subvolume we just created before retrying
            eval { _api_call($scfg, 'subvolume.delete', { filesystem => $fs, name => $volname }) };
            last if $retry == $max_retries;
            select(undef, undef, undef, 0.5 * $retry);  # escalating backoff
            next;
        }

        return $volname;
    }

    die "[Nasty] alloc_image failed after $max_retries retries: $err\n";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $fs = $scfg->{nasty_filesystem};

    _log($scfg, 1, "[Nasty] free_image: $volname");

    # Get current block_device
    my $sv = eval { _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $volname }) };
    if ($@) {
        warn "[Nasty] free_image: subvolume.get failed for $volname: $@";
        return undef;
    }

    if (my $block_device = $sv->{block_device}) {
        eval { _remove_from_share($scfg, $block_device) };
        warn "[Nasty] free_image: remove_from_share warning: $@" if $@;
    }

    _api_call($scfg, 'subvolume.delete', { filesystem => $fs, name => $volname });
    # Verify deletion actually completed — NASty subvolume.delete returns before
    # the subvolume is physically gone; it can take 2-3 minutes for the subvolume to
    # disappear from subvolume.list. Use aggressive retries to avoid stale cache
    # entries confusing pvesm list during VM deletion.
    my $deleted = 0;
    for my $try (1..30) {
        eval {
            _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $volname });
        };
        if ($@) {
            $deleted = 1;
        }
        warn "[Nasty] free_image: subvolume still exists after delete (try $try)" unless $deleted;
        last if $deleted;
        sleep(5) if $try < 30;
    }

    warn "[Nasty] free_image: subvolume $volname may not have been deleted" unless $deleted;
    $deleted or return undef;

    return undef;
}

sub _resolve_dev_path {
    my ($scfg, $block_device) = @_;
    my $mode = $scfg->{nasty_transport_mode} // 'iscsi';

    if ($mode eq 'iscsi') {
        my $lun_id = _iscsi_find_lun($scfg, $block_device);
        unless (defined $lun_id) {
            # Namespace may have been removed from the share (e.g. stale volume after NASty
            # restart). Re-expose it so path() can proceed and free_image can clean up.
            _log($scfg, 2, "[Nasty] _resolve_dev_path: LUN missing for $block_device, re-exposing");
            _add_to_share($scfg, $block_device);
            $lun_id = _iscsi_find_lun($scfg, $block_device);
            die "[Nasty] no LUN found for block device $block_device after re-exposing\n" unless defined $lun_id;
        }
        _iscsi_login($scfg);
        my $dev = _iscsi_rescan($scfg, $lun_id);
        die "[Nasty] device not found for LUN $lun_id after rescan\n" unless $dev;
        return _untaint_abs_path($dev);
    } elsif ($mode eq 'nvme-tcp') {
        # Find NSID from the NASty API, then locate /dev/nvme<ctrl>n<nsid>
        my $nsid = _nvme_find_ns($scfg, $block_device);
        unless (defined $nsid) {
            # Namespace may have been removed from the share (e.g. stale volume after NASty
            # restart). Re-expose it so path() can proceed and free_image can clean up.
            _log($scfg, 2, "[Nasty] _resolve_dev_path: NVMe namespace missing for $block_device, re-exposing");
            _add_to_share($scfg, $block_device);
            $nsid = _nvme_find_ns($scfg, $block_device);
            die "[Nasty] no NVMe namespace found for block device $block_device after re-exposing\n" unless defined $nsid;
        }
        _nvme_connect($scfg);
        my $dev = _nvme_find_dev_by_nsid($scfg, $nsid);
        die "[Nasty] NVMe device not found for NSID $nsid after connect\n" unless $dev;
        return _untaint_abs_path($dev);
    } else {
        die "[Nasty] unknown transport mode '$mode'\n";
    }
}

sub _snapclone_volname {
    my ($scfg, $volname, $snapname) = @_;
    my $prefix = $scfg->{nasty_subvolume_prefix};
    # volname is like "pve/vm-100-disk-0", extract disk part after prefix/
    (my $diskpart = $volname) =~ s!^\Q$prefix\E/!!;
    return "$prefix/pve-snapclone-$diskpart-$snapname";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $fs = $scfg->{nasty_filesystem};

    if ($snapname) {
        # vzdump snap-clone flow: clone snapshot → expose → return dev path
        my $clone_name = _snapclone_volname($scfg, $volname, $snapname);

        # Create clone if it doesn't already exist
        my $existing = eval { _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $clone_name }) };
        die $@ if $@ && $@ !~ /not found/i;
        unless ($existing) {
            _api_call($scfg, 'snapshot.clone', {
                filesystem => $fs,
                subvolume  => $volname,
                snapshot   => $snapname,
                new_name   => $clone_name,
            });
            $existing = _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $clone_name });
        }

        my $block_device = $existing->{block_device}
            or die "[Nasty] snap-clone $clone_name has no block_device\n";

        # Expose if not already in share
        my $already = ($scfg->{nasty_transport_mode} // 'iscsi') eq 'iscsi'
            ? _iscsi_find_lun($scfg, $block_device)
            : _nvme_find_ns($scfg, $block_device);

        _add_to_share($scfg, $block_device) unless defined $already;

        # Ensure transport is connected
        my $mode = $scfg->{nasty_transport_mode} // 'iscsi';
        $mode eq 'iscsi' ? _iscsi_login($scfg) : _nvme_connect($scfg);

        return (_resolve_dev_path($scfg, $block_device), undef, 'raw');
    }

    # No snapname: resolve current block device
    my $sv = _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $volname });
    my $block_device = $sv->{block_device}
        or die "[Nasty] $volname has no block_device\n";

    return (_resolve_dev_path($scfg, $block_device), undef, 'raw');
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $mode = $scfg->{nasty_transport_mode} // 'iscsi';

    if ($snapname) {
        # Snap-clone path: path() does the heavy lifting
        my (undef) = path($class, $scfg, $volname, $storeid, $snapname);
        return 1;
    }

    # Normal volume: ensure transport is connected
    $mode eq 'iscsi' ? _iscsi_login($scfg) : _nvme_connect($scfg);
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    unless ($snapname) {
        # Shared target stays connected — no-op
        return 1;
    }

    # Tear down snap-clone
    my $fs         = $scfg->{nasty_filesystem};
    my $clone_name = _snapclone_volname($scfg, $volname, $snapname);

    my $existing = eval { _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $clone_name }) };
    die $@ if $@ && $@ !~ /not found/i;
    unless ($existing) {
        _log($scfg, 1, "[Nasty] deactivate_volume: snap-clone $clone_name not found, nothing to do");
        return 1;
    }

    if (my $block_device = $existing->{block_device}) {
        eval { _remove_from_share($scfg, $block_device) };
        warn "[Nasty] deactivate snap-clone: remove_from_share warning: $@" if $@;
    }

    eval { _api_call($scfg, 'subvolume.delete', { filesystem => $fs, name => $clone_name }) };
    warn "[Nasty] deactivate snap-clone: delete warning: $@" if $@;

    return 1;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    my $features = {
        snapshot => { current => 1 },
        clone    => { current => 1, snap => 1 },
        copy     => { current => 1, snap => 1 },
    };

    my $key = $snapname ? 'snap' : 'current';
    return ($features->{$feature} && $features->{$feature}->{$key}) ? 1 : undef;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    _log($scfg, 1, "[Nasty] volume_snapshot: $volname @ $snap");

    _api_call($scfg, 'snapshot.create', {
        filesystem => $scfg->{nasty_filesystem},
        subvolume  => $volname,
        name       => $snap,
        read_only  => \1,  # NASty always creates read-only; be explicit
    });

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $fs = $scfg->{nasty_filesystem};
    my $clone_name = _snapclone_volname($scfg, $volname, $snap);
    # Clean up any stale snapshot clone if it exists
    my $existing;
    eval {
        $existing = _api_call($scfg, 'subvolume.get', { filesystem => $fs, name => $clone_name });
    };
    if ($existing) {
        _log($scfg, 1, "[Nasty] cleaning up stale snap-clone: $clone_name");
        if (my $bd = $existing->{block_device}) {
            eval { _remove_from_share($scfg, $bd) };
            warn "[Nasty] snap-clone cleanup share removal warning: $@" if $@;
        }
        eval { _api_call($scfg, 'subvolume.delete', { filesystem => $fs, name => $clone_name }) };
        warn "[Nasty] snap-clone cleanup delete warning: $@" if $@;
    }
    # 1. Delete the snapshot
    _api_call($scfg, 'snapshot.delete', {
        filesystem => $fs,
        subvolume  => $volname,
        name       => $snap,
    });

    return undef;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    die "[Nasty] snapshot rollback is not supported (bcachefs limitation)\n";
}


sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $snapshots = _api_call($scfg, 'snapshot.list', {
        filesystem => $scfg->{nasty_filesystem},
    });

    my $res = {};
    for my $s (@$snapshots) {
        next unless $s->{subvolume} eq $volname;
        my $name = $s->{name} // next;
        $res->{$name} = {
            id        => $name,
            timestamp => 0,  # NASty API does not expose snapshot creation time
        };
    }

    return $res;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $sv = _api_call($scfg, 'subvolume.get', {
        filesystem => $scfg->{nasty_filesystem},
        name       => $volname,
    });

    my $bytes = $sv->{volsize_bytes} // 0;
    my $used  = $sv->{used_bytes} // 0;
    return wantarray ? ($bytes, 'raw', $used, undef) : $bytes;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    # size arrives in bytes from Proxmox
    _log($scfg, 1, "[Nasty] volume_resize: $volname to $size bytes");

    _api_call($scfg, 'subvolume.resize', {
        filesystem    => $scfg->{nasty_filesystem},
        name          => $volname,
        volsize_bytes => 0 + $size,
    });

    # Give NASty a moment to propagate the size change before returning
    select(undef, undef, undef, 1);

    return undef;
}

1;

