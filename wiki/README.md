<p align="center">
  <img src="../docs/assets/nastyplugin-logo.svg" alt="NastyPlugin" width="640" />
</p>

# NastyPlugin for Proxmox VE

A Proxmox VE custom storage plugin that exposes a NASty NAS appliance as shared block storage
via iSCSI or NVMe-TCP.

## Pages

- [Installation](Installation.md) — install and remove the .deb package
- [Configuration](Configuration.md) — NASty appliance setup, storage.cfg keys, and `pvesm add`
- [Changelog](Changelog.md) — release history

## Requirements

- Proxmox VE 8.0+
- NASty appliance with a configured bcachefs filesystem
- `open-iscsi` (iSCSI transport) or `nvme-cli` (NVMe-TCP transport)

## Support

Open an issue on GitHub.
