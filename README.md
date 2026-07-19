<p align="center">
  <img src="docs/assets/nastyplugin-logo.svg" alt="NastyPlugin" width="640" />
</p>

# NastyPlugin for Proxmox VE

A Proxmox VE custom storage plugin that exposes a [NASty](https://github.com/nasty-project/nasty)
NAS appliance as shared block storage via iSCSI or NVMe-TCP. VM disks are backed by bcachefs
Block subvolumes on the NASty appliance and presented as raw block devices to Proxmox.

## Features

- **Copy-on-write snapshots** — near-instant, space-efficient VM snapshots backed by bcachefs
- **Transparent compression** — reduces VM disk footprint without manual tuning
- **Data integrity** — bcachefs checksumming detects silent corruption
- **Shared block storage** — enables live migration across all nodes in a PVE cluster
- **Dual transport** — iSCSI for broad compatibility, NVMe-TCP for lower latency
- **Thin provisioning** — VM disks allocated on demand, no capacity pre-reserved

## Requirements

- Proxmox VE 8.0+
- NASty appliance with a configured bcachefs filesystem
- `open-iscsi` (iSCSI transport) or `nvme-cli` (NVMe-TCP transport)

## Quick Start

```bash
dpkg -i nasty-proxmox-plugin_*.deb
```

See [wiki/Installation.md](wiki/Installation.md) and [wiki/Configuration.md](wiki/Configuration.md).

## Documentation

- [Installation](wiki/Installation.md)
- [Configuration](wiki/Configuration.md)
- [Changelog](wiki/Changelog.md)

## License

GPL-3.0. See [LICENSE](LICENSE).

---

**Version:** 0.1.13 — 2026-07-19
