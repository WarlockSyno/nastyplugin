# Changelog

## 0.1.1 — 2026-05-31

- Added Proxmox storage API compatibility declaration for PVE 8/9 custom plugin loading.
- Fixed WebSocket response handling to skip initial authentication broadcasts and runtime event frames.
- Fixed NASty block subvolume naming to use flat volume names accepted by the appliance API.
- Fixed numeric JSON encoding for allocate and resize requests.
- Fixed snapshot info return shape for the current Proxmox storage wrapper API.
- Fixed iSCSI path resolution to ensure target login and keep iscsiadm output from polluting `pvesm path`.
- Updated the full-function test script for current Proxmox CLI behavior.
- Expanded the NASty full-function test script to mirror the TrueNAS plugin test function coverage with NASty-specific backend checks.

## 0.1.0 — 2026-05-31

- Initial release.
- iSCSI and NVMe-oF transport support.
- Full Proxmox storage plugin interface: alloc, free, list, snapshot, resize, path.
