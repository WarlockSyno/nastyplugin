# Installation

## Quick Install

```bash
dpkg -i nasty-proxmox-plugin_0.1.0_all.deb
```

Then configure storage:

```bash
pvesm add nastyplugin my-nasty \
  --nasty_api_host 10.15.15.60 \
  --nasty_api_token YOUR_TOKEN \
  --nasty_filesystem tank \
  --nasty_subvolume_prefix pve \
  --nasty_transport_mode iscsi \
  --nasty_iscsi_target iqn.2026-01.com.nasty:pve
```

## Building from Source

```bash
cd nastyplugin
tools/build-deb.sh
```
