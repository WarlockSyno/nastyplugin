# Configuration

## NASty Appliance Setup

Before adding the storage to Proxmox, configure the NASty appliance:

1. **Enable the transport service** — go to **System → Services** and enable iSCSI, NVMe-oF, or both.
   Enabling a service automatically creates a default target (iSCSI) or subsystem (NVMe-oF) with a
   generated IQN/NQN. Note the IQN or NQN — you will need it below.

2. **Create an API token** — go to **System → Access Control → Tokens & Keys** and create a token.
   Copy the token value.

## Quick Start

### Using `pvesm add`

```bash
# iSCSI
pvesm add nastyplugin my-nasty \
  --nasty_api_host 10.15.15.60 \
  --nasty_api_token YOUR_TOKEN \
  --nasty_filesystem tank \
  --nasty_subvolume_prefix pve \
  --nasty_transport_mode iscsi \
  --nasty_iscsi_target iqn.2137-04.storage.nasty:proxmox \
  --content images,rootdir \
  --shared 1

# NVMe-TCP
pvesm add nastyplugin my-nasty \
  --nasty_api_host 10.15.15.60 \
  --nasty_api_token YOUR_TOKEN \
  --nasty_filesystem tank \
  --nasty_subvolume_prefix pve \
  --nasty_transport_mode nvme-tcp \
  --nasty_nvme_subsystem nqn.2137-04.storage.nasty:proxmox \
  --content images,rootdir \
  --shared 1
```

### Using `/etc/pve/storage.cfg` directly

```
nastyplugin: my-nasty
    nasty_api_host 10.15.15.60
    nasty_api_token YOUR_TOKEN
    nasty_filesystem tank
    nasty_subvolume_prefix pve
    nasty_transport_mode iscsi
    nasty_iscsi_target iqn.2137-04.storage.nasty:proxmox
    content images,rootdir
    shared 1
```

## Required Keys

| Key | Description |
|-----|-------------|
| `nasty_api_host` | NASty appliance hostname or IP |
| `nasty_api_token` | API token (Bearer auth) |
| `nasty_filesystem` | bcachefs filesystem name (e.g. `tank`) |
| `nasty_subvolume_prefix` | Prefix for all VM disk names (e.g. `pve`) |
| `nasty_transport_mode` | Transport protocol: `iscsi` (default) or `nvme-tcp` |

## Transport: iSCSI

Set `nasty_transport_mode iscsi` and provide:

| Key | Description |
|-----|-------------|
| `nasty_iscsi_target` | iSCSI target IQN (shown on the NASty Services page) |

## Transport: NVMe-TCP

Set `nasty_transport_mode nvme-tcp` and provide:

| Key | Description |
|-----|-------------|
| `nasty_nvme_subsystem` | NVMe-oF subsystem NQN (shown on the NASty Services page) |

## Optional Keys

| Key | Default | Description |
|-----|---------|-------------|
| `nasty_nvme_hostnqn` | auto-detected | Host NQN override for NVMe-TCP (auto-detected if not set) |
| `nasty_api_port` | `443` | WebSocket port |
| `nasty_api_scheme` | `wss` | `wss` or `ws` |
| `nasty_api_verify_ssl` | `1` | TLS certificate verification (`0` to disable) |
| `nasty_log_level` | `1` | `0` = errors only, `1` = info, `2` = debug |
