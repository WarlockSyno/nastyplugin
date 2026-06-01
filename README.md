# NastyPlugin for Proxmox VE

**Version:** 0.1.3 — 2026-06-01

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

## Testing

The development full-function test script mirrors the TrueNAS plugin test function coverage while adapting backend checks to NASty storage semantics, including batched pre-flight cleanup for the test VMID range.

## Changelog

See [wiki/Changelog.md](wiki/Changelog.md).
