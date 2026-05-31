# NastyPlugin for Proxmox VE

**Version:** 0.1.0 — 2026-05-31

A Proxmox VE custom storage plugin that exposes a [Nasty](https://github.com/nasty-project/nasty)
NAS appliance as shared block storage. VM disks are bcachefs Block subvolumes on Nasty,
exposed over iSCSI or NVMe-oF (NVMe/TCP).

## Requirements

- Proxmox VE 8.0+
- Nasty appliance with a configured bcachefs filesystem
- `open-iscsi` (iSCSI transport) or `nvme-cli` (NVMe-oF transport)

## Installation

See [wiki/Installation.md](wiki/Installation.md).

## Configuration

See [wiki/Configuration.md](wiki/Configuration.md).

## Changelog

See [wiki/Changelog.md](wiki/Changelog.md).
