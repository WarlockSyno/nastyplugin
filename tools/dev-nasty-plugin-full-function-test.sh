#!/usr/bin/env bash
# Full-function end-to-end test for nastyplugin.
# Run on a Proxmox node that has the plugin installed.
#
# Usage: ./dev-nasty-plugin-full-function-test.sh <storage-id> <vmid>
# Example: ./dev-nasty-plugin-full-function-test.sh nasty-test 9999

set -euo pipefail

STORAGE="${1:?Usage: $0 <storage-id> <vmid>}"
VMID="${2:?Usage: $0 <storage-id> <vmid>}"
SNAP="testsnap1"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

echo "=== NastyPlugin E2E Test ==="
echo "Storage: $STORAGE  VMID: $VMID"
echo

# 1. Storage status
echo "--- 1. Storage status ---"
pvesm status --storage "$STORAGE" || fail "status failed"
pass "storage status"

# 2. Allocate a disk
echo "--- 2. alloc_image ---"
VOLID=$(pvesm alloc "$STORAGE" "$VMID" "" 1G 2>&1)
echo "  Allocated: $VOLID"
[[ -n "$VOLID" ]] || fail "alloc returned empty"
VOLNAME="${VOLID#*:}"
pass "alloc_image"

# 3. List images — should contain our new volume
echo "--- 3. list_images ---"
pvesm list "$STORAGE" --vmid "$VMID" | grep "$VOLNAME" || fail "volume not in list"
pass "list_images"

# 4. Snapshot
echo "--- 4. volume_snapshot ---"
pvesm snapshot "$STORAGE:$VOLNAME" "$SNAP" || fail "snapshot failed"
pass "volume_snapshot"

# 5. volume_snapshot_info
echo "--- 5. volume_snapshot_info ---"
pvesm snapinfo "$STORAGE:$VOLNAME" "$SNAP" || fail "snapinfo failed"
pass "volume_snapshot_info"

# 6. Snapshot delete
echo "--- 6. volume_snapshot_delete ---"
pvesm delsnapshot "$STORAGE:$VOLNAME" "$SNAP" || fail "delsnapshot failed"
pass "volume_snapshot_delete"

# 7. volume_resize
echo "--- 7. volume_resize ---"
pvesm resize "$STORAGE:$VOLNAME" 2G || fail "resize failed"
pass "volume_resize"

# 8. volume_size_info
echo "--- 8. volume_size_info ---"
pvesm volumeinfo "$STORAGE:$VOLNAME" || fail "volumeinfo failed"
pass "volume_size_info"

# 9. path
echo "--- 9. path ---"
DEV=$(pvesm path "$STORAGE:$VOLNAME")
echo "  Device: $DEV"
[[ -b "$DEV" ]] || fail "path did not return a block device"
pass "path"

# 10. Free image
echo "--- 10. free_image ---"
pvesm free "$STORAGE:$VOLNAME" || fail "free failed"
pvesm list "$STORAGE" --vmid "$VMID" | grep "$VOLNAME" && fail "volume still in list after free"
pass "free_image"

echo
echo "=== All tests passed ==="
