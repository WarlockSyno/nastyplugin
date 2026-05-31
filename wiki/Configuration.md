# Configuration Reference

All keys use the `nasty_` prefix in `/etc/pve/storage.cfg`.

## Required Keys

| Key | Description |
|-----|-------------|
| `nasty_api_host` | Nasty appliance hostname or IP |
| `nasty_api_token` | API token (Bearer auth) |
| `nasty_filesystem` | bcachefs filesystem name (e.g. `tank`) |
| `nasty_subvolume_prefix` | Parent subvolume for all VM disks (e.g. `pve`) |
| `nasty_transport_mode` | Transport protocol: `iscsi` (default) or `nvme-tcp` |

## Transport: iSCSI (default)

Set `nasty_transport_mode iscsi` and:

| Key | Description |
|-----|-------------|
| `nasty_iscsi_target` | iSCSI target IQN |

## Transport: NVMe-oF

Set `nasty_transport_mode nvme-tcp` and:

| Key | Description |
|-----|-------------|
| `nasty_nvme_subsystem` | NVMe-oF subsystem name |
| `nasty_nvme_hostnqn` | Host NQN (auto-detected if not set) |

## Optional Keys

| Key | Default | Description |
|-----|---------|-------------|
| `nasty_api_port` | `443` | WebSocket port |
| `nasty_api_scheme` | `wss` | `wss` or `ws` |
| `nasty_api_verify_ssl` | `1` | TLS cert verification |
| `nasty_log_level` | `1` | 0=err 1=info 2=debug |
