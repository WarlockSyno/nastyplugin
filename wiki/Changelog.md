# Changelog
## 0.1.9 — 2026-07-05
- Fixed unused variable in `free_image` (removed dead `$err` assignment).
- Fixed subvolume leak in `alloc_image`: orphaned subvolumes now cleaned up on `subvolume.create` failure, `_add_to_share` failure, or missing `block_device`.
- Fixed orphaned comment numbering in `volume_snapshot_delete`.

- Fixed NVMe Phase 4 disk deletion failures: added 150s retry loop in `free_image` to wait for
  NASty subvolume deletion to complete before returning. NASty's `subvolume.delete` returns
  immediately but the subvolume may take 2-3 minutes to fully disappear.
- Added stale subvolume filtering in `list_images` by validating each entry with `subvolume.get`.
- Removed cached `subvolume.list` entries from `%API_CACHE` to prevent stale deletion artifacts.
- Added concurrent allocation retry loop in `alloc_image` (3 retries, escalating backoff) to
  handle simultaneous VM disk creation.


## 0.1.7 — 2026-06-02

- Fixed a crash when activating or deleting a volume whose block device had been removed from the
  storage target (e.g. after a NASty restart or a previous incomplete cleanup). The plugin now
  re-attaches the block device automatically and retries, allowing the operation to complete cleanly.

## 0.1.6 — 2026-06-01

- Fixed spurious kernel log errors (`NON_EXISTENT_LUN`) that appeared during disk deletion when
  using iSCSI transport. The target-side cleanup now happens before the initiator-side cleanup,
  preventing the kernel from retrying commands against a LUN that no longer exists.
- Improved stability of the NASty API connection under transient network blips; added a short
  backoff between retries.

## 0.1.5 — 2026-06-01

- Fixed snapshot info returning an invalid timestamp (NASty does not provide snapshot creation
  times; the plugin now correctly returns a zero value).
- Fixed snapshots not being marked read-only at creation time.

## 0.1.4 — 2026-06-01

- Fixed VM disk names to use the correct format expected by the NASty API.
- Fixed storage activation creating an unnecessary directory structure that prevented VM disk
  creation from succeeding. Disk directories are now created automatically on first use.

## 0.1.3 — 2026-06-01

- Updated compatibility to Proxmox VE storage API level 14.
- Fixed NVMe-TCP disk discovery when multiple NVMe controllers are present on the host.
- Fixed a crash on Proxmox installations running in taint mode (the default).
- Fixed NVMe-TCP activation when a previous connection attempt left a stale session.
- Fixed live VM migration over NVMe-TCP on hosts that share a NVMe host identifier with
  another storage system.
- Fixed dropped API connections after Proxmox forks a child process (e.g. during LXC backup).

## 0.1.2 — 2026-06-01

- Fixed iSCSI ghost devices accumulating on the Proxmox host after disk deletion, which
  caused `NON_EXISTENT_LUN` kernel log spam on subsequent operations.

## 0.1.1 — 2026-05-31

- Fixed plugin loading on Proxmox VE 8 and 9.
- Fixed several issues with iSCSI path resolution, NVMe-TCP device discovery, snapshot
  handling, and volume size reporting.
- Improved reliability of the full-function test suite.

## 0.1.0 — 2026-05-31

- Initial release.
- iSCSI and NVMe-TCP transport support.
- Full Proxmox storage plugin interface: create, delete, list, snapshot, resize, path.
