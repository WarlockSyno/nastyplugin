# Changelog

## 0.1.5 — 2026-06-01

- Fixed `volume_snapshot_info` to not reference the absent `created_at` field (NASty snapshot API returns no timestamp); timestamps now explicitly return 0.
- Fixed `snapshot.create` to explicitly pass `read_only: true`, matching the NASty engine's actual behaviour.

## 0.1.4 — 2026-06-01

- Fixed volname separator: all subvolume names now use slash (`pve/vm-100-disk-0`) matching the NASty API path model, replacing the incorrect dash convention.
- Fixed `activate_storage`: removed erroneous prefix Filesystem subvolume creation, which blocked all subsequent Block subvolume creation under the prefix; prefix directory is now created implicitly by the NASty engine on first `alloc_image`.

## 0.1.3 — 2026-06-01

- Updated storage API compatibility to PVE API level 14 (system APIVER=14, APIAGE=5).
- Replaced NVMe device discovery: `_nvme_rescan` removed in favour of `_nvme_find_dev_by_nsid`, which locates the NVMe-TCP controller by NQN in sysfs and returns `/dev/nvme<ctrl>n<nsid>` — correct even when multiple controllers are present or controller indices change.
- Fixed taint-mode crash in `_iscsi_remove_scsi_device`: `readlink()` returns tainted strings; extract the device name with a capturing regex to untaint it before use in `open()` (pvedaemon runs with `-T`).
- Fixed WebSocket stale-connection failure after forked child (e.g., LXC clone rsync) closes the inherited socket: `_api_call` now retries once on send/recv errors after dropping the cached connection.
- Fixed NVMe idempotent activation: detect an already-live controller by subsystem NQN in sysfs before running `nvme connect`, avoiding the nvme-cli `already connected` exit-1 path during `pvesm free` and deletion cleanup.
- Fixed NVMe live migration when other NVMe/TCP sessions on the destination use the same `/etc/nvme/hostid` with a different hostnqn: `nvme connect` now passes a deterministic hostid derived from the NASty hostnqn.

## 0.1.2 — 2026-06-01

- Fixed iSCSI ghost device leak: remove the initiator-side SCSI disk node via sysfs before removing a LUN from the NASty target, preventing stale 0-byte devices and NON_EXISTENT_LUN kernel spam.

## 0.1.1 — 2026-05-31

- Added Proxmox storage API compatibility declaration for PVE 8/9 custom plugin loading.
- Fixed WebSocket response handling to skip initial authentication broadcasts and runtime event frames.
- Fixed NASty block subvolume naming to use flat volume names accepted by the appliance API.
- Fixed numeric JSON encoding for allocate and resize requests.
- Fixed snapshot info return shape for the current Proxmox storage wrapper API.
- Fixed iSCSI path resolution to ensure target login and keep iscsiadm output from polluting `pvesm path`.
- Updated the full-function test script for current Proxmox CLI behavior.
- Expanded the NASty full-function test script to mirror the TrueNAS plugin test function coverage with NASty-specific backend checks.
- Optimized pre-flight cleanup in the full-function test script to avoid silent per-VMID storage scans.
- Fixed full-function test failure accounting so error logging cannot break shell returns.
- Fixed `volume_size_info` scalar-context return for Proxmox 9 disk attachment and resize validation.
- Advertised snapshot/clone/copy feature support to Proxmox and untainted device paths for LXC rootfs formatting.
- Fixed full-function test NASty API helper JSON parameter handling and single-phase reruns.

## 0.1.0 — 2026-05-31

- Initial release.
- iSCSI and NVMe-oF transport support.
- Full Proxmox storage plugin interface: alloc, free, list, snapshot, resize, path.
