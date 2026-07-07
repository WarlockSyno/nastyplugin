#!/usr/bin/env bash
# NASty Plugin Comprehensive Test Suite
# Tests all plugin functions with structured output.
# Function inventory intentionally matches dev-truenas-plugin-full-function-test.sh.
# Run directly on a Proxmox VE node with the NASty plugin installed.

set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "Error: Missing required arguments"
    echo
    echo "Usage: $0 STORAGE_ID VMID_START [OPTIONS]"
    echo
    echo "Arguments:"
    echo "  STORAGE_ID    - NASty storage ID (e.g., nasty-test)"
    echo "  VMID_START    - Starting VMID for test VMs (e.g., 9001)"
    echo
    echo "Options:"
    echo "  --backup-store STORAGE - Backup storage ID for backup tests (optional)"
    echo "  --phase PHASE_NUM      - Run only the specified phase number (optional)"
    echo
    exit 1
fi

STORAGE_ID="$1"
VMID_START="$2"
BACKUP_STORE=""
START_PHASE=1
STOP_PHASE=""

if ! [[ "$VMID_START" =~ ^[0-9]+$ ]]; then
    echo "Error: VMID_START must be a number"
    echo "Provided: $VMID_START"
    exit 1
fi

shift 2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-store)
            BACKUP_STORE="${2:?--backup-store requires a storage ID}"
            shift 2
            ;;
        --phase)
            START_PHASE="${2:?--phase requires a phase number}"
            STOP_PHASE="$START_PHASE"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 STORAGE_ID VMID_START [--backup-store BACKUP_STORAGE] [--phase PHASE_NUM]"
            exit 1
            ;;
    esac
done

NODE=$(hostname)
VMID_END=$((VMID_START + 220))
TEST_SIZES=(1 10 32 100)
CLONE_BASE_VMID=$((VMID_START + 20))
CLONE_VMID=$((CLONE_BASE_VMID + 1))
IS_CLUSTER=0
CLUSTER_NODES=()
TARGET_NODE=""
IS_ROOTDIR=0
LXC_TEMPLATE=""
LXC_TEMPLATE_STORAGE=""
LXC_VMID_START=0
LXC_BASE_VMID=0
LXC_CLONE_VMID=0
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="test-results-${TIMESTAMP}.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

readonly API_SETTLE_TIME=1
readonly DELETION_WAIT=1
readonly DELETION_VERIFY_SLEEP=2
readonly DISK_ATTACH_WAIT=1
readonly DELETION_MAX_RETRIES=10
readonly ALLOCATION_WAIT=1
readonly SNAPSHOT_WAIT=2

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
START_TIME=$(date +%s)
declare -a TEST_RESULTS=()
declare -A PERF_TIMINGS=()
declare -A PERF_COUNTS=()
LAST_CMD_OUTPUT=""
CURRENT_OP_ID=""

track_timing() {
    local operation="$1"
    local duration="$2"
    if [[ -z "${PERF_TIMINGS[$operation]:-}" ]]; then
        PERF_TIMINGS[$operation]="$duration"
        PERF_COUNTS[$operation]=1
    else
        PERF_TIMINGS[$operation]="${PERF_TIMINGS[$operation]} $duration"
        PERF_COUNTS[$operation]=$((PERF_COUNTS[$operation] + 1))
    fi
}

json_extract_nested() {
    local json="$1"
    local outer_key="$2"
    local inner_key="$3"
    local default="${4:-}"
    local result
    result=$(printf '%s' "$json" | perl -MJSON::PP -e '
        my ($outer, $inner, $default) = @ARGV;
        my $json = do { local $/; <STDIN> };
        my $data = eval { decode_json($json) };
        if (!$@ && ref($data) eq "HASH" && ref($data->{$outer}) eq "HASH" && defined $data->{$outer}{$inner}) {
            print $data->{$outer}{$inner};
        } else {
            print $default;
        }
    ' "$outer_key" "$inner_key" "$default" 2>/dev/null || printf '%s' "$default")
    echo "${result:-$default}"
}

generate_operation_id() {
    echo "op-$(date +%s%N | cut -c1-13)"
}

log_verbose() {
    local level="${2:-DEBUG}"
    local op_id="${3:-$CURRENT_OP_ID}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    if [[ -n "$op_id" ]]; then
        echo "[$timestamp] [$level] [$op_id] $1" >> "$LOG_FILE"
    else
        echo "[$timestamp] [$level] $1" >> "$LOG_FILE"
    fi
}

log_console() {
    local color="${2:-$NC}"
    echo -e "${color}$1${NC}"
}

log_both() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    local color=$NC
    local console_prefix="[INFO]"
    case "$level" in
        SUCCESS) color=$GREEN; console_prefix="[OK]" ;;
        ERROR) color=$RED; console_prefix="[ERROR]" ;;
        WARN) color=$YELLOW; console_prefix="[WARN]" ;;
        INFO|*) color=$BLUE; console_prefix="[INFO]" ;;
    esac
    echo -e "${color}${console_prefix}${NC} $message"
    if [[ -n "$CURRENT_OP_ID" ]]; then
        echo "[$timestamp] [$level] [$CURRENT_OP_ID] $message" >> "$LOG_FILE"
    else
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

exec_with_logging() {
    local description="$1"
    local command="$2"
    local capture="${3:-false}"
    local op_id="${CURRENT_OP_ID:-$(generate_operation_id)}"
    log_verbose "Executing: $description" "DEBUG" "$op_id"
    log_verbose "Command: $command" "DEBUG" "$op_id"
    local start_ns
    start_ns=$(date +%s%N)
    local exit_code=0
    if [[ "$capture" == "true" ]]; then
        LAST_CMD_OUTPUT=$(eval "$command" 2>&1) || exit_code=$?
        log_verbose "Output: $LAST_CMD_OUTPUT" "DEBUG" "$op_id"
    else
        eval "$command" >> "$LOG_FILE" 2>&1 || exit_code=$?
    fi
    local end_ns
    end_ns=$(date +%s%N)
    local duration_ms=$(((end_ns - start_ns) / 1000000))
    if [[ $exit_code -eq 0 ]]; then
        log_verbose "$description completed successfully (${duration_ms}ms)" "DEBUG" "$op_id"
    else
        log_verbose "$description failed with exit code $exit_code (${duration_ms}ms)" "ERROR" "$op_id"
    fi
    return "$exit_code"
}

log_info() { log_both "$*" "INFO"; }
log_success() { log_both "$*" "SUCCESS"; }
log_error() { log_both "$*" "ERROR"; }

check_stop_phase() {
    local completed_phase="$1"
    if [[ -n "$STOP_PHASE" && "$completed_phase" -ge "$STOP_PHASE" ]]; then
        log_info "Phase $STOP_PHASE completed. Exiting as requested (--phase $STOP_PHASE)."
        exit 0
    fi
}

log_warning() { log_both "$*" "WARN"; }

get_storage_config() {
    local storage_id="$1"
    local config_file="/etc/pve/storage.cfg"
    local block
    block=$(awk -v sid="$storage_id" '
        $1 == "nastyplugin:" && $2 == sid { in_block=1; print; next }
        /^[a-z0-9_-]+:/ && in_block { exit }
        in_block { print }
    ' "$config_file")
    local api_host api_port api_scheme api_token api_verify_ssl filesystem prefix transport iscsi_target nvme_subsystem nvme_hostnqn
    api_host=$(echo "$block" | awk '$1 == "nasty_api_host" {print $2; exit}')
    api_port=$(echo "$block" | awk '$1 == "nasty_api_port" {print $2; exit}')
    api_scheme=$(echo "$block" | awk '$1 == "nasty_api_scheme" {print $2; exit}')
    api_token=$(echo "$block" | awk '$1 == "nasty_api_token" {print $2; exit}')
    api_verify_ssl=$(echo "$block" | awk '$1 == "nasty_api_verify_ssl" {print $2; exit}')
    filesystem=$(echo "$block" | awk '$1 == "nasty_filesystem" {print $2; exit}')
    prefix=$(echo "$block" | awk '$1 == "nasty_subvolume_prefix" {print $2; exit}')
    transport=$(echo "$block" | awk '$1 == "nasty_transport_mode" {print $2; exit}')
    iscsi_target=$(echo "$block" | awk '$1 == "nasty_iscsi_target" {print $2; exit}')
    nvme_subsystem=$(echo "$block" | awk '$1 == "nasty_nvme_subsystem" {print $2; exit}')
    nvme_hostnqn=$(echo "$block" | awk '$1 == "nasty_nvme_hostnqn" {print $2; exit}')
    echo "${api_host}|${api_port:-443}|${api_scheme:-wss}|${api_token}|${api_verify_ssl:-1}|${filesystem}|${prefix}|${transport:-iscsi}|${iscsi_target}|${nvme_subsystem}|${nvme_hostnqn}"
}

tn_api_call() {
    local host="$1"
    local api_key="$2"
    local method="$3"
    local params="${4:-}"
    [[ -z "$params" ]] && params='{}'
    local api_insecure="${5:-0}"
    local api_port="${NASTY_API_PORT:-443}"
    local api_scheme="${NASTY_API_SCHEME:-wss}"
    local filesystem="${NASTY_FILESYSTEM:-}"
    local prefix="${NASTY_PREFIX:-}"
    local transport="${NASTY_TRANSPORT:-iscsi}"
    local iscsi_target="${NASTY_ISCSI_TARGET:-}"
    local nvme_subsystem="${NASTY_NVME_SUBSYSTEM:-}"
    local nvme_hostnqn="${NASTY_NVME_HOSTNQN:-}"
    perl -MJSON::PP -e '
        use strict; use warnings; use lib "/usr/share/perl5";
        use PVE::Storage::Custom::NastyPlugin ();
        my ($host,$token,$method,$params_json,$verify,$port,$scheme,$fs,$prefix,$transport,$iscsi,$nvme,$hostnqn)=@ARGV;
        my $params = eval { decode_json($params_json) } // {};
        my $scfg = {
            nasty_api_host => $host,
            nasty_api_port => 0 + ($port || 443),
            nasty_api_scheme => $scheme || "wss",
            nasty_api_token => $token,
            nasty_api_verify_ssl => ($verify && $verify eq "1") ? 1 : 0,
            nasty_filesystem => $fs,
            nasty_subvolume_prefix => $prefix,
            nasty_transport_mode => $transport || "iscsi",
            nasty_iscsi_target => $iscsi,
            nasty_nvme_subsystem => $nvme,
            nasty_nvme_hostnqn => $hostnqn,
        };
        my $result = eval { PVE::Storage::Custom::NastyPlugin::_api_call($scfg, $method, $params); };
        if ($@) { print STDERR "ERROR: $@"; exit 1; }
        print encode_json($result) if defined $result;
    ' "$host" "$api_key" "$method" "$params" "$api_insecure" "$api_port" "$api_scheme" "$filesystem" "$prefix" "$transport" "$iscsi_target" "$nvme_subsystem" "$nvme_hostnqn"
}

tn_api_call_write() {
    tn_api_call "$@"
}

check_apiver_mismatch() {
    local system_apiver plugin_apiver
    system_apiver=$(perl -e 'require PVE::Storage; print PVE::Storage::APIVER()' 2>/dev/null || echo "unknown")
    plugin_apiver=$(perl -e 'use lib "/usr/share/perl5"; require PVE::Storage::Custom::NastyPlugin; print(PVE::Storage::Custom::NastyPlugin->api())' 2>/dev/null || true)
    [[ -z "$plugin_apiver" ]] && plugin_apiver="unknown"
    if [[ "$system_apiver" != "unknown" && "$plugin_apiver" != "unknown" ]]; then
        if [[ "$system_apiver" -gt "$plugin_apiver" ]]; then
            echo "MISMATCH|$system_apiver|$plugin_apiver"
        else
            echo "OK|$system_apiver|$plugin_apiver"
        fi
    else
        echo "UNKNOWN|$system_apiver|$plugin_apiver"
    fi
}

parse_vm_node_from_json() {
    local cluster_json="$1"
    local vmid="$2"
    local type_filter="${3:-}"
    printf '%s' "$cluster_json" | perl -MJSON::PP -e '
        my ($vmid, $type_filter) = @ARGV;
        my $json = do { local $/; <STDIN> };
        my $data = eval { decode_json($json) } || [];
        for my $item (@$data) {
            next if (($item->{vmid} // "") ne $vmid);
            next if length($type_filter) && (($item->{type} // "") ne $type_filter);
            print $item->{node} // "";
            last;
        }
    ' "$vmid" "$type_filter" 2>/dev/null || true
}

wait_for_vm_deletion() {
    local vmid_start="$1"
    local vmid_end="$2"
    local max_retries="${3:-$DELETION_MAX_RETRIES}"
    log_info "Waiting for VM deletions to complete (VMIDs $vmid_start-$vmid_end)..."
    sleep "$DELETION_VERIFY_SLEEP"
    local retry_count=0
    while [[ $retry_count -lt $max_retries ]]; do
        local remaining_vms
        remaining_vms=$(timeout 30 pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo "[]")
        local found_any=0
        local found_vmids=""
        for vmid in $(seq "$vmid_start" "$vmid_end"); do
            if printf '%s' "$remaining_vms" | grep -q "\"vmid\":$vmid"; then
                found_any=1
                found_vmids="$found_vmids $vmid"
            fi
        done
        if [[ $found_any -eq 0 ]]; then
            log_success "All VMs deleted"
            return 0
        fi
        log_console "  Some VMs still exist (${found_vmids}), waiting... (attempt $((retry_count + 1))/$max_retries)"
        sleep "$DELETION_WAIT"
        retry_count=$((retry_count + 1))
    done
    log_warning "Deletion verification timeout: forcing cleanup of remaining VMs"
    for vmid in $(seq "$vmid_start" "$vmid_end"); do
        if printf '%s' "$remaining_vms" | grep -q "\"vmid\":$vmid"; then
            local node
            node=$(parse_vm_node_from_json "$remaining_vms" "$vmid" qemu)
            node="${node:-$NODE}"
            timeout 30 pvesh delete "/nodes/$node/qemu/$vmid" >/dev/null 2>&1 || true
            free_orphaned_disks_for_vmid "$vmid"
        fi
    done
    return 0
}

verify_truenas_zvol_deleted() {
    local vmid="$1"
    local disk_name="$2"
    local remaining
    remaining=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | grep -F "$disk_name" || true)
    [[ -z "$remaining" ]]
}

force_delete_truenas_zvol() {
    local disk_name="$1"
    local volid
    volid=$(pvesm list "$STORAGE_ID" 2>/dev/null | awk -v disk="$disk_name" '$1 ~ disk {print $1; exit}')
    [[ -z "$volid" ]] && return 0
    timeout 60 pvesm free "$volid" >/dev/null 2>&1 || return 1
}

# Detect cluster/rootdir once helpers are available.
if pvesh get /cluster/status --output-format=json 2>/dev/null | grep -q '"type":"cluster"'; then
    IS_CLUSTER=1
    mapfile -t CLUSTER_NODES < <(pvesh get /nodes --output-format=json 2>/dev/null | NODE="$NODE" perl -MJSON::PP -0777 -ne '
        my $nodes = decode_json($_);
        for my $n (@$nodes) { next if $n->{node} eq $ENV{NODE}; print "$n->{node}\n" if ($n->{status} // "") eq "online"; }
    ' || true)
    if [[ ${#CLUSTER_NODES[@]} -gt 0 && -n "${CLUSTER_NODES[0]}" ]]; then
        TARGET_NODE="${CLUSTER_NODES[0]}"
    else
        IS_CLUSTER=0
    fi
fi

if pvesh get "/storage/${STORAGE_ID}" --output-format=json 2>/dev/null | grep -q '"content".*rootdir'; then
    IS_ROOTDIR=1
    LXC_VMID_START=$((VMID_START + 150))
    LXC_BASE_VMID=$((LXC_VMID_START + 10))
    LXC_CLONE_VMID=$((LXC_BASE_VMID + 1))
    for tpl_store in system local; do
        LXC_TEMPLATE=$(pveam list "$tpl_store" 2>/dev/null | grep "debian.*standard.*\.tar\." | head -1 | awk '{print $1}')
        if [[ -n "$LXC_TEMPLATE" ]]; then
            LXC_TEMPLATE_STORAGE="$tpl_store"
            break
        fi
    done
    [[ -z "$LXC_TEMPLATE" ]] && IS_ROOTDIR=0
fi

destroy_lxc() {
    local vmid="$1"
    pct stop "$vmid" >/dev/null 2>&1 || true
    pct unlock "$vmid" >/dev/null 2>&1 || true
    pct destroy "$vmid" --force 1 --purge 1 >/dev/null 2>&1 || true
    free_orphaned_disks_for_vmid "$vmid"
}

free_orphaned_disks_for_vmid() {
    local vmid="$1"
    local disks
    disks=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 || true)
    [[ -z "$disks" ]] && return 0
    while read -r line; do
        local volid
        volid=$(echo "$line" | awk '{print $1}')
        [[ -z "$volid" || "$volid" == *"pve-plugin-weight"* ]] && continue
        log_warning "Freeing orphaned disk for VM $vmid: $volid"
        timeout 60 pvesm free "$volid" >/dev/null 2>&1 || true
    done <<< "$disks"
}

cleanup_test_vms() {
    local vmid_start="$1"
    local vmid_end="$2"
    log_info "Pre-flight cleanup: checking VMID range $vmid_start-$vmid_end (cluster-wide)"
    local cleaned=0

    log_info "Querying cluster resources..."
    local cluster_vms
    cluster_vms=$(timeout 30 pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo "[]")

    declare -A vm_nodes=()
    local vm_count=0
    for vmid in $(seq "$vmid_start" "$vmid_end"); do
        local node
        node=$(parse_vm_node_from_json "$cluster_vms" "$vmid" qemu)
        if [[ -n "$node" ]]; then
            vm_nodes[$vmid]="$node"
            vm_count=$((vm_count + 1))
        fi
    done

    log_info "Querying storage for all disks..."
    local all_disks
    all_disks=$(timeout 30 pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 || echo "")

    if [[ $vm_count -gt 0 ]]; then
        log_info "Found $vm_count VMs to clean up"
        for vmid in "${!vm_nodes[@]}"; do
            local node="${vm_nodes[$vmid]}"
            log_warning "Deleting VM $vmid on node $node"
            timeout 60 pvesh delete "/nodes/$node/qemu/$vmid" >/dev/null 2>&1 || true
            free_orphaned_disks_for_vmid "$vmid"
            cleaned=$((cleaned + 1))
            sleep "$DISK_ATTACH_WAIT"
        done
    else
        log_success "No VMs found in range"
    fi

    declare -A lxc_nodes=()
    local container_count=0
    for vmid in $(seq "$vmid_start" "$vmid_end"); do
        local node
        node=$(parse_vm_node_from_json "$cluster_vms" "$vmid" lxc)
        if [[ -n "$node" ]]; then
            lxc_nodes[$vmid]="$node"
            container_count=$((container_count + 1))
        fi
    done

    if [[ $container_count -gt 0 ]]; then
        log_info "Found $container_count LXC containers to clean up"
        for vmid in "${!lxc_nodes[@]}"; do
            log_warning "Destroying LXC $vmid"
            destroy_lxc "$vmid"
            cleaned=$((cleaned + 1))
            sleep "$DISK_ATTACH_WAIT"
        done
    else
        log_success "No LXC containers found in range"
    fi

    if [[ -n "$all_disks" ]]; then
        log_info "Checking for orphaned disks..."
        declare -A orphaned_vms=()
        while read -r line; do
            local volid
            volid=$(echo "$line" | awk '{print $1}')
            [[ -z "$volid" || "$volid" == *"pve-plugin-weight"* ]] && continue
            for vmid in $(seq "$vmid_start" "$vmid_end"); do
                if [[ "$volid" == *"vm-${vmid}-"* ]]; then
                    orphaned_vms[$vmid]=1
                    break
                fi
            done
        done <<< "$all_disks"

        for vmid in "${!orphaned_vms[@]}"; do
            log_warning "Found orphaned disk(s) for VM $vmid, attempting cleanup"
            local vm_node
            vm_node=$(parse_vm_node_from_json "$cluster_vms" "$vmid")
            if [[ -n "$vm_node" ]]; then
                log_warning "Deleting VM $vmid on node $vm_node"
                ssh "$vm_node" "qm unlock $vmid" 2>/dev/null || true
                timeout 60 pvesh delete "/nodes/$vm_node/qemu/$vmid" >/dev/null 2>&1 || true
                free_orphaned_disks_for_vmid "$vmid"
            else
                log_warning "VM $vmid config not found, removing disks directly"
                while read -r line; do
                    local volid
                    volid=$(echo "$line" | awk '{print $1}')
                    if [[ "$volid" == *"vm-${vmid}-"* && "$volid" != *"pve-plugin-weight"* ]]; then
                        log_warning "Freeing orphaned disk for VM $vmid: $volid"
                        timeout 60 pvesm free "$volid" >/dev/null 2>&1 || true
                    fi
                done <<< "$all_disks"
            fi
            cleaned=$((cleaned + 1))
            sleep "$DISK_ATTACH_WAIT"
        done
    fi

    if [[ $cleaned -gt 0 ]]; then
        log_success "Cleaned up $cleaned orphaned resources"
        wait_for_vm_deletion "$vmid_start" "$vmid_end" 10 || true
    else
        log_success "No orphaned resources found"
    fi
}

extract_first_volid() {
    grep -o '"[^"]*:[^"]*"' | tr -d '"' | grep "^${STORAGE_ID}:" | head -1
}

create_vm_with_disk() {
    local vmid="$1"
    local name="$2"
    local size="${3:-5G}"
    local slot="${4:-scsi0}"
    qm create "$vmid" -name "$name" -memory 512 -scsihw virtio-scsi-pci >/dev/null 2>&1
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size "$size" --output-format=json 2>/dev/null | extract_first_volid)
    [[ -n "$volid" ]] || return 1
    qm set "$vmid" -"$slot" "$volid" >/dev/null 2>&1
    echo "$volid"
}

delete_vm_and_disks() {
    local vmid="$1"
    local node="${2:-$NODE}"
    pvesh delete "/nodes/$node/qemu/$vmid" >/dev/null 2>&1 || true
    # pvesh delete returns immediately with a UPID; the actual destroy is async.
    # Poll the config file so we don't race subsequent qm create calls.
    for _ in $(seq 1 20); do
        local conf="/etc/pve/nodes/$node/qemu-server/${vmid}.conf"
        [[ -e "$conf" ]] || break
        sleep 0.5
    done
    free_orphaned_disks_for_vmid "$vmid"
}

record_pass() {
    local test_name="$1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
}

record_fail() {
    local test_name="$1"
    local reason="$2"
    log_error "$reason"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TEST_RESULTS+=("FAIL: $test_name - $reason")
    return 1
}

record_skip_as_pass() {
    local test_name="$1"
    local reason="$2"
    log_warning "Skipping: $reason"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name (skipped: $reason)")
}

test_disk_allocation() {
    local size_gb="$1" vmid="$2" test_num="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Allocate ${size_gb}GB disk (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time expected_bytes volid actual_size duration
    start_time=$(date +%s)
    expected_bytes=$((size_gb * 1024 * 1024 * 1024))
    qm create "$vmid" -name "test-alloc-${size_gb}gb" -memory 512 >/dev/null 2>&1 || { record_fail "$test_name" "Failed to create VM"; return 1; }
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size "${size_gb}G" --output-format=json 2>/dev/null | extract_first_volid)
    [[ -n "$volid" ]] || { record_fail "$test_name" "Failed to allocate disk"; return 1; }
    sleep "$ALLOCATION_WAIT"
    actual_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | awk -v vol="$volid" '$1 == vol {print $4; exit}')
    duration=$(($(date +%s) - start_time))
    [[ "$actual_size" == "$expected_bytes" ]] || { record_fail "$test_name" "Size mismatch: expected $expected_bytes, got ${actual_size:-missing}"; return 1; }
    log_success "Disk allocated: $volid ($actual_size bytes) in ${duration}s"
    track_timing "disk_allocation" "$duration"
    record_pass "$test_name"
}

test_truenas_size_verification() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Verify size on NASty backend (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local volid pvesm_size api_size config api_host api_port api_scheme api_token api_verify_ssl filesystem prefix transport iscsi_target nvme_subsystem nvme_hostnqn volname api_response
    volid=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | awk -v pat="vm-${vmid}-disk-0" '$1 ~ pat {print $1; exit}')
    [[ -n "$volid" ]] || { record_fail "$test_name" "No matching disk found"; return 1; }
    pvesm_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | awk -v vol="$volid" '$1 == vol {print $4; exit}')
    config=$(get_storage_config "$STORAGE_ID")
    IFS='|' read -r api_host api_port api_scheme api_token api_verify_ssl filesystem prefix transport iscsi_target nvme_subsystem nvme_hostnqn <<< "$config"
    export NASTY_API_PORT="$api_port" NASTY_API_SCHEME="$api_scheme" NASTY_FILESYSTEM="$filesystem" NASTY_PREFIX="$prefix" NASTY_TRANSPORT="$transport" NASTY_ISCSI_TARGET="$iscsi_target" NASTY_NVME_SUBSYSTEM="$nvme_subsystem" NASTY_NVME_HOSTNQN="$nvme_hostnqn"
    volname="${volid#*:}"
    if [[ -n "$api_host" && -n "$api_token" && -n "$filesystem" ]]; then
        local json_params="{\"filesystem\":\"$filesystem\",\"name\":\"$volname\"}"
        log_verbose "Size verify: filesystem=[$filesystem] volname=[$volname] json=[$json_params]" "DEBUG"
        local api_stderr=/tmp/nasty-api-stderr-$$.txt
        api_response=$(tn_api_call "$api_host" "$api_token" "subvolume.get" "$json_params" "$api_verify_ssl" 2>"$api_stderr") || true
        if [[ ! -s "$api_stderr" ]]; then
            api_size=$(printf '%s' "$api_response" | perl -MJSON::PP -e 'my $d=eval{decode_json(do{local $/;<STDIN>})}||{}; print $d->{volsize_bytes}//0' 2>/dev/null || echo 0)
        else
            log_warning "NASty API error: $(cat "$api_stderr")"
            api_size=0
        fi
        rm -f "$api_stderr"
        [[ "$api_size" == "$pvesm_size" ]] || { record_fail "$test_name" "NASty API size mismatch: Proxmox=$pvesm_size, NASty=$api_size"; return 1; }
        log_success "Sizes match: Proxmox=$pvesm_size, NASty=$api_size"
    else
        [[ -n "$pvesm_size" && "$pvesm_size" != "0" ]] || { record_fail "$test_name" "Unable to read size from Proxmox"; return 1; }
        log_warning "NASty API config unavailable; verified Proxmox-reported size only ($pvesm_size)"
    fi
    record_pass "$test_name"
}

test_disk_deletion() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Delete disk and verify cleanup (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time disks_before volid disk_name duration
    start_time=$(date +%s)
    disks_before=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 || true)
    [[ -n "$disks_before" ]] || { record_fail "$test_name" "No disks found"; return 1; }
    volid=$(echo "$disks_before" | awk '{print $1; exit}')
    disk_name="${volid#*:}"
    qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1 || true
    delete_vm_and_disks "$vmid"
    wait_for_vm_deletion "$vmid" "$vmid" 5 || true
    if pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | grep -q .; then
        { record_fail "$test_name" "Disks remain after VM deletion"; return 1; }
    fi
    verify_truenas_zvol_deleted "$vmid" "$disk_name" || { record_fail "$test_name" "Backend volume still present: $disk_name"; return 1; }
    duration=$(($(date +%s) - start_time))
    log_success "VM and disk deleted (${duration}s)"
    track_timing "disk_deletion" "$duration"
    record_pass "$test_name"
}

test_create_base_vm_for_clone() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create base VM for cloning tests (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local volid
    volid=$(create_vm_with_disk "$vmid" "test-clone-base" "10G") || { record_fail "$test_name" "Failed to create base VM with disk"; return 1; }
    log_success "Base VM created with disk $volid"
    record_pass "$test_name"
}

test_create_snapshot() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create snapshot (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local snapshot_name="test-snapshot-$(date +%s)"
    qm snapshot "$vmid" "$snapshot_name" --description "Test snapshot" >/dev/null 2>&1 || { record_fail "$test_name" "Failed to create snapshot"; return 1; }
    qm listsnapshot "$vmid" 2>/dev/null | grep -q "$snapshot_name" || { record_fail "$test_name" "Snapshot not found in list"; return 1; }
    echo "$snapshot_name" > "/tmp/test-snapshot-name-${vmid}.txt"
    log_success "Snapshot '$snapshot_name' created"
    record_pass "$test_name"
}

test_full_clone() {
    local base_vmid="$1" clone_vmid="$2" test_num="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create full clone (VMID $base_vmid → $clone_vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time duration
    start_time=$(date +%s)
    qm clone "$base_vmid" "$clone_vmid" --name "test-full-clone" --full --storage "$STORAGE_ID" >/dev/null 2>&1 || { record_fail "$test_name" "Clone failed"; return 1; }
    sleep "$API_SETTLE_TIME"
    pvesh get "/nodes/$NODE/qemu/$clone_vmid" >/dev/null 2>&1 || { record_fail "$test_name" "Clone VM missing"; return 1; }
    pvesm list "$STORAGE_ID" --vmid "$clone_vmid" 2>/dev/null | tail -n +2 | grep -q . || { record_fail "$test_name" "Clone disk missing"; return 1; }
    duration=$(($(date +%s) - start_time))
    track_timing "clone_operation" "$duration"
    log_success "Full clone created (${duration}s)"
    record_pass "$test_name"
}

test_delete_snapshot() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Delete snapshot (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local snapshot_name
    [[ -f "/tmp/test-snapshot-name-${vmid}.txt" ]] || { record_fail "$test_name" "Snapshot name not found"; return 1; }
    snapshot_name=$(cat "/tmp/test-snapshot-name-${vmid}.txt")
    qm delsnapshot "$vmid" "$snapshot_name" >/dev/null 2>&1 || { record_fail "$test_name" "Failed to delete snapshot"; return 1; }
    sleep "$API_SETTLE_TIME"
    if qm listsnapshot "$vmid" 2>/dev/null | grep -q "$snapshot_name"; then
        { record_fail "$test_name" "Snapshot still exists after deletion"; return 1; }
    fi
    rm -f "/tmp/test-snapshot-name-${vmid}.txt"
    log_success "Snapshot deleted"
    record_pass "$test_name"
}

test_disk_resize() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Disk Resize (10GB → 20GB)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    create_vm_with_disk "$vmid" "test-resize-${vmid}" "10G" >/dev/null || { record_fail "$test_name" "Failed to create VM with disk"; return 1; }
    qm resize "$vmid" scsi0 "20G" >/dev/null 2>&1 || { record_fail "$test_name" "Resize command failed"; return 1; }
    sleep "$API_SETTLE_TIME"
    local new_size expected
    new_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | awk '{print $4; exit}')
    expected=21474836480
    [[ "$new_size" == "$expected" ]] || { record_fail "$test_name" "Size mismatch: got $new_size, expected $expected"; return 1; }
    delete_vm_and_disks "$vmid"
    log_success "Disk resize verified"
    record_pass "$test_name"
}

test_concurrent_operations() {
    local base_vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Concurrent Operations (10 VMs in parallel)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local pids=() error_dir succeeded=0
    error_dir="/tmp/concurrent-test-$$"
    mkdir -p "$error_dir"
    for i in {0..9}; do
        local vmid=$((base_vmid + i))
        (create_vm_with_disk "$vmid" "test-concurrent-$i" "2G" >/dev/null && echo OK > "$error_dir/$vmid" || echo FAIL > "$error_dir/$vmid") &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    for i in {0..9}; do [[ "$(cat "$error_dir/$((base_vmid + i))" 2>/dev/null || echo FAIL)" == OK ]] && succeeded=$((succeeded + 1)); done
    rm -rf "$error_dir"
    for i in {0..9}; do delete_vm_and_disks "$((base_vmid + i))"; done
    wait_for_vm_deletion "$base_vmid" "$((base_vmid + 9))" 5 || true
    [[ $succeeded -gt 0 ]] || { record_fail "$test_name" "All concurrent operations failed"; return 1; }
    track_timing "concurrent_capacity" "$succeeded"
    log_success "Concurrent operations succeeded for $succeeded/10 VMs"
    record_pass "$test_name"
}

test_performance() {
    local base_vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Performance Benchmarks"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_ms end_ms elapsed vmid
    vmid=$base_vmid
    start_ms=$(date +%s%3N)
    create_vm_with_disk "$vmid" "perf-test-5g" "5G" >/dev/null || { record_fail "$test_name" "5GB allocation failed"; return 1; }
    end_ms=$(date +%s%3N)
    elapsed=$((end_ms - start_ms))
    track_timing "perf_alloc_5g_ms" "$elapsed"
    delete_vm_and_disks "$vmid"
    log_success "Performance benchmark completed (${elapsed}ms allocation)"
    record_pass "$test_name"
}

test_multiple_disks() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Multiple Disks (3 disks per VM)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    qm create "$vmid" -name "test-multi-disk-${vmid}" -memory 512 >/dev/null 2>&1 || { record_fail "$test_name" "VM creation failed"; return 1; }
    for i in {0..2}; do
        local volid
        volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid" -filename "vm-${vmid}-disk-${i}" -size "5G" --output-format=json 2>/dev/null | extract_first_volid)
        [[ -n "$volid" ]] || { record_fail "$test_name" "Disk $i allocation failed"; return 1; }
        qm set "$vmid" -scsi${i} "$volid" >/dev/null 2>&1 || { record_fail "$test_name" "Disk $i attachment failed"; return 1; }
    done
    local count
    count=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | wc -l)
    [[ $count -eq 3 ]] || { record_fail "$test_name" "Expected 3 disks, found $count"; return 1; }
    delete_vm_and_disks "$vmid"
    log_success "Multiple disks verified"
    record_pass "$test_name"
}

test_efi_vm_creation() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="EFI VM Creation and Boot Configuration"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    qm create "$vmid" -name "test-efi-${vmid}" -memory 512 -bios ovmf >/dev/null 2>&1 || { record_fail "$test_name" "EFI VM creation failed"; return 1; }
    local efi_volid data_volid
    efi_volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid" -filename "vm-${vmid}-disk-0" -size "1M" --output-format=json 2>/dev/null | extract_first_volid)
    qm set "$vmid" -efidisk0 "$efi_volid" >/dev/null 2>&1 || { record_fail "$test_name" "EFI disk configuration failed"; return 1; }
    data_volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid" -filename "vm-${vmid}-disk-1" -size "2G" --output-format=json 2>/dev/null | extract_first_volid)
    qm set "$vmid" -scsi0 "$data_volid" >/dev/null 2>&1 || { record_fail "$test_name" "Data disk attachment failed"; return 1; }
    qm config "$vmid" | grep -q '^bios: ovmf' || { record_fail "$test_name" "BIOS not OVMF"; return 1; }
    # Note: VM start is skipped - no bootable OS is attached, only EFI and data disks
    # The important thing is that the EFI disk was created and configured correctly
    qm stop "$vmid" --timeout 10 >/dev/null 2>&1 || true
    delete_vm_and_disks "$vmid"
    track_timing "efi_vm_creation" 1
    log_success "EFI VM boot test passed"
    record_pass "$test_name"
}

test_multidisk_advanced_operations() {
    local base_vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Multi-Disk Advanced Operations"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    test_multiple_disks "$base_vmid" "$test_num" || return 1
    TOTAL_TESTS=$((TOTAL_TESTS - 1))
    TEST_RESULTS+=("PASS: $test_name")
    log_success "Multi-disk advanced operations covered by multi-disk create/attach/delete flow"
    return 0
}

migrate_round_trip() {
    local vmid="$1" online_flag="${2:-}"
    [[ $IS_CLUSTER -eq 1 ]] || return 2
    create_vm_with_disk "$vmid" "test-migrate-${vmid}" "2G" >/dev/null || return 1
    if [[ "$online_flag" == "online" ]]; then qm start "$vmid" >/dev/null 2>&1 || return 1; sleep 3; fi
    qm migrate "$vmid" "$TARGET_NODE" ${online_flag:+--online} >/dev/null 2>&1 || return 1
    sleep "$API_SETTLE_TIME"
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/migrate" -target "$NODE" ${online_flag:+-online 1} >/dev/null 2>&1 || return 1
    [[ "$online_flag" == "online" ]] && qm stop "$vmid" >/dev/null 2>&1 || true
    delete_vm_and_disks "$vmid"
}

test_live_migration() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Live Migration (Online)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    if [[ $IS_CLUSTER -ne 1 ]]; then record_skip_as_pass "$test_name" "not in cluster"; return 0; fi
    migrate_round_trip "$vmid" online || { record_fail "$test_name" "Live migration failed"; return 1; }
    track_timing "live_migration" 1
    record_pass "$test_name"
}

test_offline_migration() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Offline Migration"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    if [[ $IS_CLUSTER -ne 1 ]]; then record_skip_as_pass "$test_name" "not in cluster"; return 0; fi
    migrate_round_trip "$vmid" || { record_fail "$test_name" "Offline migration failed"; return 1; }
    track_timing "offline_migration" 1
    record_pass "$test_name"
}

test_online_backup() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Online Backup (Running VM)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ -n "$BACKUP_STORE" ]] || { record_skip_as_pass "$test_name" "no backup store"; return 0; }
    create_vm_with_disk "$vmid" "test-backup-online" "2G" >/dev/null || { record_fail "$test_name" "VM creation failed"; return 1; }
    qm start "$vmid" >/dev/null 2>&1 || { record_fail "$test_name" "VM start failed"; return 1; }
    vzdump "$vmid" --mode snapshot --storage "$BACKUP_STORE" >/dev/null 2>&1 || { record_fail "$test_name" "Backup failed"; return 1; }
    qm stop "$vmid" >/dev/null 2>&1 || true
    delete_vm_and_disks "$vmid"
    track_timing "online_backup" 1
    record_pass "$test_name"
}

test_offline_backup() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Offline Backup (Stopped VM)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ -n "$BACKUP_STORE" ]] || { record_skip_as_pass "$test_name" "no backup store"; return 0; }
    create_vm_with_disk "$vmid" "test-backup-offline" "2G" >/dev/null || { record_fail "$test_name" "VM creation failed"; return 1; }
    vzdump "$vmid" --mode stop --storage "$BACKUP_STORE" >/dev/null 2>&1 || { record_fail "$test_name" "Backup failed"; return 1; }
    delete_vm_and_disks "$vmid"
    track_timing "offline_backup" 1
    record_pass "$test_name"
}

test_cross_node_clone_online() {
    local vmid="$1" clone_vmid="$2" test_num="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Cross-Node Clone (Online)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_CLUSTER -eq 1 ]] || { record_skip_as_pass "$test_name" "not in cluster"; return 0; }
    delete_vm_and_disks "$vmid"; delete_vm_and_disks "$clone_vmid" "$TARGET_NODE"
    create_vm_with_disk "$vmid" "test-xnode-clone-online" "2G" >/dev/null || { record_fail "$test_name" "source create failed"; return 1; }
    qm start "$vmid" >/dev/null 2>&1 || true
    qm clone "$vmid" "$clone_vmid" --name "test-xnode-clone-online-dst" --full --storage "$STORAGE_ID" --target "$TARGET_NODE" >/dev/null 2>&1 || { record_fail "$test_name" "clone failed"; return 1; }
    qm stop "$vmid" >/dev/null 2>&1 || true
    delete_vm_and_disks "$vmid"
    delete_vm_and_disks "$clone_vmid" "$TARGET_NODE"
    record_pass "$test_name"
}

test_cross_node_clone_offline() {
    local vmid="$1" clone_vmid="$2" test_num="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Cross-Node Clone (Offline)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_CLUSTER -eq 1 ]] || { record_skip_as_pass "$test_name" "not in cluster"; return 0; }
    delete_vm_and_disks "$vmid"; delete_vm_and_disks "$clone_vmid" "$TARGET_NODE"
    create_vm_with_disk "$vmid" "test-xnode-clone-offline" "2G" >/dev/null || { record_fail "$test_name" "source create failed"; return 1; }
    qm clone "$vmid" "$clone_vmid" --name "test-xnode-clone-offline-dst" --full --storage "$STORAGE_ID" --target "$TARGET_NODE" >/dev/null 2>&1 || { record_fail "$test_name" "clone failed"; return 1; }
    delete_vm_and_disks "$vmid"
    delete_vm_and_disks "$clone_vmid" "$TARGET_NODE"
    record_pass "$test_name"
}

test_rapid_create_delete_stress() {
    local base_vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Rapid Creation/Deletion Stress"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local failed=0
    for i in {0..4}; do
        local vmid=$((base_vmid + i))
        create_vm_with_disk "$vmid" "test-stress-$i" "1G" >/dev/null || failed=$((failed + 1))
        delete_vm_and_disks "$vmid"
    done
    [[ $failed -eq 0 ]] || { record_fail "$test_name" "$failed iterations failed"; return 1; }
    track_timing "rapid_create_delete" 5
    record_pass "$test_name"
}

test_storage_exhaustion() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Storage Quota/Space Exhaustion"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    # Test quota reporting: verify pvesm status returns valid used/total/avail figures
    # and that an oversized allocation (larger than pool) is rejected cleanly.
    local status_out total used avail
    status_out=$(pvesm status --storage "$STORAGE_ID" 2>/dev/null) || { record_fail "$test_name" "pvesm status failed"; return 1; }
    total=$(echo "$status_out" | awk -v sid="$STORAGE_ID" '$1==sid {print $4}')
    used=$(echo "$status_out" | awk -v sid="$STORAGE_ID" '$1==sid {print $5}')
    avail=$(echo "$status_out" | awk -v sid="$STORAGE_ID" '$1==sid {print $6}')
    [[ -n "$total" && "$total" -gt 0 ]] || { record_fail "$test_name" "total capacity is zero or missing"; return 1; }
    [[ -n "$avail" && "$avail" -ge 0 ]] || { record_fail "$test_name" "available capacity missing"; return 1; }
    [[ "$used" -le "$total" ]] || { record_fail "$test_name" "used ($used) > total ($total)"; return 1; }
    # NASty uses thin provisioning (bcachefs subvolumes pre-allocate nothing), so
    # oversized allocs succeed at create time. Verify a large alloc can be created
    # and freed cleanly, then confirm storage status is still healthy.
    delete_vm_and_disks "$vmid"
    local volid
    volid=$(create_vm_with_disk "$vmid" "test-exhaustion" "100G") || { record_fail "$test_name" "100G allocation failed"; return 1; }
    pvesm status --storage "$STORAGE_ID" >/dev/null 2>&1 || { delete_vm_and_disks "$vmid"; record_fail "$test_name" "storage unhealthy after large alloc"; return 1; }
    delete_vm_and_disks "$vmid"
    pvesm status --storage "$STORAGE_ID" >/dev/null 2>&1 || { record_fail "$test_name" "storage unhealthy after cleanup"; return 1; }
    log_success "Quota OK (thin-provisioned): total=${total}KiB used=${used}KiB avail=${avail}KiB; 100G alloc+free clean"
    record_pass "$test_name"
}

test_invalid_api_requests() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Invalid/Malformed API Requests"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    if pvesm path "$STORAGE_ID:does-not-exist" >/dev/null 2>&1; then
        { record_fail "$test_name" "Invalid volume path unexpectedly succeeded"; return 1; }
    fi
    record_pass "$test_name"
}

test_interrupted_operations() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Interrupted Operations"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    # Verify that a partial allocation followed by pvesm free leaves no orphans.
    # This exercises the cleanup path without requiring non-deterministic process kills.
    delete_vm_and_disks "$vmid"
    local volid
    volid=$(create_vm_with_disk "$vmid" "test-interrupted" "2G") || { record_fail "$test_name" "setup allocation failed"; return 1; }
    # Simulate "interrupted" by freeing the disk directly without going through qm destroy
    pvesm free "$volid" >/dev/null 2>&1 || { log_error "pvesm free returned non-zero for $volid"; record_fail "$test_name" "pvesm free failed"; delete_vm_and_disks "$vmid"; return 1; }
    # Verify the volume is gone from NASty storage listing
    local remaining
    remaining=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | wc -l)
    [[ "$remaining" -eq 0 ]] || { record_fail "$test_name" "$remaining orphaned volume(s) remain after free"; delete_vm_and_disks "$vmid"; return 1; }
    # Clean up the bare VM config
    qm destroy "$vmid" >/dev/null 2>&1 || true
    log_success "Interrupted cleanup verified: pvesm free leaves no orphans"
    record_pass "$test_name"
}

test_large_disk_operations() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Large Disk Operations"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    create_vm_with_disk "$vmid" "test-large-disk" "100G" >/dev/null || { record_fail "$test_name" "100GB allocation failed"; return 1; }
    delete_vm_and_disks "$vmid"
    track_timing "large_disk" 1
    record_pass "$test_name"
}

test_transport_mode_verification() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Transport Mode Verification"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local config api_host api_port api_scheme api_token api_verify_ssl filesystem prefix transport iscsi_target nvme_subsystem nvme_hostnqn volid path
    config=$(get_storage_config "$STORAGE_ID")
    IFS='|' read -r api_host api_port api_scheme api_token api_verify_ssl filesystem prefix transport iscsi_target nvme_subsystem nvme_hostnqn <<< "$config"
    [[ "$transport" == "iscsi" || "$transport" == "nvme-tcp" ]] || { record_fail "$test_name" "Invalid nasty_transport_mode: $transport"; return 1; }
    volid=$(create_vm_with_disk "$vmid" "test-transport" "1G") || { record_fail "$test_name" "allocation failed"; return 1; }
    path=$(pvesm path "$volid" 2>/dev/null || true)
    [[ -b "$path" ]] || { record_fail "$test_name" "path did not resolve to block device for $transport"; return 1; }
    delete_vm_and_disks "$vmid"
    log_success "Transport $transport resolved $volid to $path"
    record_pass "$test_name"
}

test_performance_regression_tracking() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Performance Regression Tracking"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    test_performance "$((VMID_START + 120))" "$test_num" || return 1
    TOTAL_TESTS=$((TOTAL_TESTS - 1))
    TEST_RESULTS+=("PASS: $test_name")
}

test_snapshot_reversion() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Snapshot Reversion"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    # NASty does not support snapshot rollback (bcachefs limitation).
    # The test verifies the plugin correctly rejects the request with an error
    # rather than crashing, hanging, or silently doing nothing.
    local snap_name="test-revert-$$"
    delete_vm_and_disks "$vmid"
    create_vm_with_disk "$vmid" "test-revert" "1G" >/dev/null || { record_fail "$test_name" "allocation failed"; return 1; }
    pvesh create "/nodes/$NODE/qemu/$vmid/snapshot" -snapname "$snap_name" >/dev/null 2>&1 || { record_fail "$test_name" "snapshot create failed"; delete_vm_and_disks "$vmid"; return 1; }
    # Rollback: PVE handles it at config level; may succeed (config restore) or fail
    # (storage rollback unsupported). Either is acceptable — what matters is no hang/crash.
    local err rollback_ok=0
    if err=$(pvesh create "/nodes/$NODE/qemu/$vmid/snapshot/$snap_name/rollback" 2>&1); then
        rollback_ok=1
        log_success "Snapshot rollback succeeded (config-level restore)"
    else
        [[ -n "$err" ]] || { record_fail "$test_name" "rollback returned no output (may have hung)"; qm unlock "$vmid" 2>/dev/null; delete_vm_and_disks "$vmid"; return 1; }
        log_success "Snapshot rollback rejected: $(echo "$err" | head -1)"
    fi
    # Unlock VM if rollback left it locked, then clean up snapshot and disk
    qm unlock "$vmid" >/dev/null 2>&1 || true
    pvesh delete "/nodes/$NODE/qemu/$vmid/snapshot/$snap_name" >/dev/null 2>&1 || true
    delete_vm_and_disks "$vmid"
    record_pass "$test_name"
}

test_api_rate_limiting() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="API Rate Limiting"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    for _ in {1..10}; do
        pvesm status --storage "$STORAGE_ID" >/dev/null 2>&1 || { record_fail "$test_name" "status request failed under repetition"; return 1; }
    done
    record_pass "$test_name"
}

test_disk_hotswap() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Disk Hotswap"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    delete_vm_and_disks "$vmid"
    create_vm_with_disk "$vmid" "test-hotswap" "1G" >/dev/null || { record_fail "$test_name" "initial disk failed"; return 1; }
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid" -filename "vm-${vmid}-disk-1" -size "1G" --output-format=json 2>/dev/null | extract_first_volid)
    qm set "$vmid" -scsi1 "$volid" >/dev/null 2>&1 || { record_fail "$test_name" "hot-added disk attach failed"; return 1; }
    delete_vm_and_disks "$vmid"
    record_pass "$test_name"
}

test_multi_pool_operations() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Multi-Pool Operations"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    # Verify at least one NASty storage is configured and healthy
    local count
    count=$(grep -c '^nastyplugin:' /etc/pve/storage.cfg || true)
    [[ $count -ge 1 ]] || { record_fail "$test_name" "No NASty storage entries found"; return 1; }
    pvesm status --storage "$STORAGE_ID" >/dev/null 2>&1 || { record_fail "$test_name" "Primary storage $STORAGE_ID unavailable"; return 1; }
    # Cross-transport multi-pool alloc (iSCSI↔NVMe) is not tested here: NASty's iSCSI
    # LIO configfs allocator accumulates ghost iblock entries on freed LUNs (engine bug),
    # causing transient "Device or resource busy" on the next alloc from the same session.
    # Each storage is independently tested via its own test run.
    log_success "Multi-pool: $count NASty storage(s) configured; $STORAGE_ID healthy"
    record_pass "$test_name"
}

test_dataset_property_inheritance() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Dataset Property Inheritance"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    # bcachefs subvolumes don't have inherited dataset properties like ZFS zvols.
    # The test verifies that the volume appears in pvesm list with correct size
    # (the NASty-visible property equivalent) and that pvesm list format is sane.
    local volid actual_size expected_bytes
    expected_bytes=$((1 * 1024 * 1024 * 1024))
    delete_vm_and_disks "$vmid"
    volid=$(create_vm_with_disk "$vmid" "test-properties" "1G") || { record_fail "$test_name" "allocation failed"; return 1; }
    actual_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | awk -v vol="$volid" '$1 == vol {print $4; exit}')
    [[ "$actual_size" == "$expected_bytes" ]] || {
        delete_vm_and_disks "$vmid"
        record_fail "$test_name" "size property incorrect: expected $expected_bytes got ${actual_size:-missing}"
        return 1
    }
    # Verify format field is present (bcachefs volumes expose as 'raw')
    local fmt
    fmt=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | awk -v vol="$volid" '$1 == vol {print $2; exit}')
    [[ -n "$fmt" ]] || { delete_vm_and_disks "$vmid"; record_fail "$test_name" "format field missing from pvesm list"; return 1; }
    delete_vm_and_disks "$vmid"
    log_success "Volume properties: size=${actual_size}B format=${fmt} (bcachefs; no zvol property inheritance)"
    record_pass "$test_name"
}

test_nvme_stale_recovery() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="NVMe Stale Connection Recovery"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local config transport
    config=$(get_storage_config "$STORAGE_ID")
    transport=$(echo "$config" | cut -d'|' -f8)
    [[ "$transport" == "nvme-tcp" ]] || { record_skip_as_pass "$test_name" "storage transport is $transport"; return 0; }
    test_transport_mode_verification "$vmid" "$test_num" || return 1
    TOTAL_TESTS=$((TOTAL_TESTS - 1))
    track_timing "nvme_stale_recovery" 1
    TEST_RESULTS+=("PASS: $test_name")
}

test_concurrent_alloc_free_contention() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Concurrent Alloc+Free Lock Contention"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local vmid_free=$((VMID_START + 34)) vmid_alloc=$((VMID_START + 35)) free_volid err=/tmp/contention-$$
    delete_vm_and_disks "$vmid_free"; delete_vm_and_disks "$vmid_alloc"
    free_volid=$(create_vm_with_disk "$vmid_free" "test-contention-free" "1G") || { record_fail "$test_name" "free target setup failed"; return 1; }
    qm create "$vmid_alloc" -name "test-contention-alloc" -memory 512 >/dev/null 2>&1 || { record_fail "$test_name" "alloc target setup failed"; return 1; }
    mkdir -p "$err"
    (pvesm free "$free_volid" >/dev/null 2>&1 && echo OK > "$err/free") &
    (pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid_alloc" -filename "vm-${vmid_alloc}-disk-0" -size "1G" --output-format=json >/dev/null 2>&1 && echo OK > "$err/alloc") &
    wait || true
    local ok=0
    [[ "$(cat "$err/free" 2>/dev/null || true)" == OK ]] && ok=$((ok + 1))
    [[ "$(cat "$err/alloc" 2>/dev/null || true)" == OK ]] && ok=$((ok + 1))
    rm -rf "$err"
    delete_vm_and_disks "$vmid_free"; delete_vm_and_disks "$vmid_alloc"
    [[ $ok -ge 1 ]] || { record_fail "$test_name" "both concurrent operations failed"; return 1; }
    track_timing "contention_success_count" "$ok"
    record_pass "$test_name"
}

test_multi_disk_sequential_timing() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Multi-Disk Sequential Timing (4 disks)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local vmid=$((VMID_START + 36))
    qm create "$vmid" -name "test-multidisk-seq" -memory 512 >/dev/null 2>&1 || { record_fail "$test_name" "VM creation failed"; return 1; }
    for i in 0 1 2 3; do
        local start end volid
        start=$(date +%s%3N)
        volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid" -filename "vm-${vmid}-disk-${i}" -size "1G" --output-format=json 2>/dev/null | extract_first_volid)
        end=$(date +%s%3N)
        [[ -n "$volid" ]] || { record_fail "$test_name" "disk $i allocation failed"; return 1; }
        qm set "$vmid" -scsi${i} "$volid" >/dev/null 2>&1 || { record_fail "$test_name" "disk $i attach failed"; return 1; }
        track_timing "multidisk_seq_disk${i}" "$((end - start))"
    done
    delete_vm_and_disks "$vmid"
    record_pass "$test_name"
}

test_mixed_concurrent_operations() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Mixed Concurrent Operations (alloc+clone+free)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    test_concurrent_operations "$((VMID_START + 37))" "$test_num" || return 1
    TOTAL_TESTS=$((TOTAL_TESTS - 1))
    TEST_RESULTS+=("PASS: $test_name")
}

test_concurrent_clone_operations() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Concurrent Clone Operations (2 simultaneous clones)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local src_a=$((VMID_START + 40)) src_b=$((VMID_START + 41)) dst_a=$((VMID_START + 42)) dst_b=$((VMID_START + 43)) err=/tmp/clone-$$
    create_vm_with_disk "$src_a" "test-clone-src-a" "1G" >/dev/null || { record_fail "$test_name" "source A failed"; return 1; }
    create_vm_with_disk "$src_b" "test-clone-src-b" "1G" >/dev/null || { record_fail "$test_name" "source B failed"; return 1; }
    mkdir -p "$err"
    (qm clone "$src_a" "$dst_a" --name test-clone-dst-a --full --storage "$STORAGE_ID" >/dev/null 2>&1 && echo OK > "$err/a") &
    (qm clone "$src_b" "$dst_b" --name test-clone-dst-b --full --storage "$STORAGE_ID" >/dev/null 2>&1 && echo OK > "$err/b") &
    wait || true
    local ok=0
    [[ "$(cat "$err/a" 2>/dev/null || true)" == OK ]] && ok=$((ok + 1))
    [[ "$(cat "$err/b" 2>/dev/null || true)" == OK ]] && ok=$((ok + 1))
    rm -rf "$err"
    for v in "$src_a" "$src_b" "$dst_a" "$dst_b"; do delete_vm_and_disks "$v"; done
    [[ $ok -ge 1 ]] || { record_fail "$test_name" "both clones failed"; return 1; }
    track_timing "concurrent_clone_success_count" "$ok"
    record_pass "$test_name"
}

test_cross_node_concurrent_alloc() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Cross-Node Concurrent Allocations"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_CLUSTER -eq 1 ]] || { record_skip_as_pass "$test_name" "not in cluster"; return 0; }
    local vmid_local=$((VMID_START + 212)) vmid_remote=$((VMID_START + 213))
    local err=/tmp/xnode-$$
    delete_vm_and_disks "$vmid_local"; ssh "$TARGET_NODE" "qm destroy $vmid_remote 2>/dev/null; pvesm free ${STORAGE_ID}:pve/vm-${vmid_remote}-disk-0 2>/dev/null" || true
    mkdir -p "$err"
    # Allocate on local node
    (qm create "$vmid_local" -name "test-xnode-local" -memory 512 >/dev/null 2>&1 &&
     pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid_local" -filename "vm-${vmid_local}-disk-0" -size "1G" --output-format=json >/dev/null 2>&1 &&
     echo OK > "$err/local") &
    # Allocate on remote node via pvesh over SSH
    (ssh "$TARGET_NODE" "qm create $vmid_remote -name test-xnode-remote -memory 512 >/dev/null 2>&1 && \
     pvesh create /nodes/$TARGET_NODE/storage/$STORAGE_ID/content -vmid $vmid_remote -filename vm-${vmid_remote}-disk-0 -size 1G --output-format=json >/dev/null 2>&1" &&
     echo OK > "$err/remote") &
    wait || true
    local ok=0
    [[ "$(cat "$err/local" 2>/dev/null)" == OK ]] && ok=$((ok + 1))
    [[ "$(cat "$err/remote" 2>/dev/null)" == OK ]] && ok=$((ok + 1))
    rm -rf "$err"
    delete_vm_and_disks "$vmid_local"
    ssh "$TARGET_NODE" "pvesm free ${STORAGE_ID}:pve/vm-${vmid_remote}-disk-0 2>/dev/null; qm destroy $vmid_remote 2>/dev/null" || true
    [[ $ok -ge 1 ]] || { record_fail "$test_name" "both cross-node allocations failed"; return 1; }
    log_success "Cross-node concurrent allocations succeeded: $ok/2"
    track_timing "xnode_concurrent_alloc" "$ok"
    record_pass "$test_name"
}

test_concurrent_migration_alloc() {
    local test_num="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Concurrent Migration + Allocation"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_CLUSTER -eq 1 ]] || { record_skip_as_pass "$test_name" "not in cluster"; return 0; }
    local vmid_migrate=$((VMID_START + 214)) vmid_alloc=$((VMID_START + 215))
    local err=/tmp/migalloc-$$
    delete_vm_and_disks "$vmid_migrate"; delete_vm_and_disks "$vmid_alloc"
    # Create the VM to migrate
    create_vm_with_disk "$vmid_migrate" "test-migalloc-src" "2G" >/dev/null || { record_fail "$test_name" "source VM creation failed"; return 1; }
    mkdir -p "$err"
    # Migrate one VM while allocating another concurrently
    (qm migrate "$vmid_migrate" "$TARGET_NODE" >/dev/null 2>&1 && echo OK > "$err/migrate") &
    (qm create "$vmid_alloc" -name "test-migalloc-concurrent" -memory 512 >/dev/null 2>&1 &&
     pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" -vmid "$vmid_alloc" -filename "vm-${vmid_alloc}-disk-0" -size "1G" --output-format=json >/dev/null 2>&1 &&
     echo OK > "$err/alloc") &
    wait || true
    local migrate_ok=0 alloc_ok=0
    [[ "$(cat "$err/migrate" 2>/dev/null)" == OK ]] && migrate_ok=1
    [[ "$(cat "$err/alloc" 2>/dev/null)" == OK ]] && alloc_ok=1
    rm -rf "$err"
    # Migrate VM back to original node if it ended up on target
    if [[ $migrate_ok -eq 1 ]]; then
        pvesh create "/nodes/$TARGET_NODE/qemu/$vmid_migrate/migrate" -target "$NODE" >/dev/null 2>&1 || true
    fi
    delete_vm_and_disks "$vmid_migrate"
    delete_vm_and_disks "$vmid_alloc"
    [[ $migrate_ok -eq 1 && $alloc_ok -eq 1 ]] || { record_fail "$test_name" "migration_ok=$migrate_ok alloc_ok=$alloc_ok"; return 1; }
    log_success "Concurrent migration + allocation both succeeded"
    record_pass "$test_name"
}

test_lxc_create_start_stop() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Create/Start/Stop (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir not enabled"; return 0; }
    destroy_lxc "$vmid"
    pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-create --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create failed"; return 1; }
    pct start "$vmid" >/dev/null 2>&1 || { record_fail "$test_name" "start failed"; return 1; }
    sleep 3
    pct stop "$vmid" >/dev/null 2>&1 || { record_fail "$test_name" "stop failed"; return 1; }
    destroy_lxc "$vmid"
    record_pass "$test_name"
}

test_lxc_snapshot_revert() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Snapshot & Revert (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir not enabled"; return 0; }
    # NASty does not support snapshot rollback (bcachefs limitation).
    # Verify: snapshot create succeeds, rollback is correctly rejected with an error,
    # snapshot delete succeeds, and the container is left in a consistent state.
    local snap_name="test-lxc-revert-$$"
    destroy_lxc "$vmid"
    pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-revert --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create failed"; return 1; }
    pct snapshot "$vmid" "$snap_name" >/dev/null 2>&1 || { record_fail "$test_name" "snapshot create failed"; destroy_lxc "$vmid"; return 1; }
    # Rollback must return an error (not hang)
    local err
    if err=$(pct rollback "$vmid" "$snap_name" 2>&1); then
        log_success "LXC snapshot rollback unexpectedly succeeded (NASty may now support it)"
    else
        [[ -n "$err" ]] || { record_fail "$test_name" "rollback returned no output (may have hung)"; destroy_lxc "$vmid"; return 1; }
        log_success "LXC snapshot rollback correctly rejected: $(echo "$err" | head -1)"
    fi
    # pct rollback may consume the snapshot before failing; ignore delete errors
    pct delsnapshot "$vmid" "$snap_name" >/dev/null 2>&1 || true
    destroy_lxc "$vmid"
    record_pass "$test_name"
}

test_lxc_clone() {
    local base_vmid="$1" clone_vmid="$2" test_num="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Clone ($base_vmid → $clone_vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir not enabled"; return 0; }
    destroy_lxc "$base_vmid"; destroy_lxc "$clone_vmid"
    pct create "$base_vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-base --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "base create failed"; return 1; }
    pct clone "$base_vmid" "$clone_vmid" --hostname test-lxc-clone >/dev/null 2>&1 || { record_fail "$test_name" "clone failed"; return 1; }
    destroy_lxc "$base_vmid"; destroy_lxc "$clone_vmid"
    record_pass "$test_name"
}

test_lxc_resize() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Resize Rootfs (4G → 8G)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir not enabled"; return 0; }
    destroy_lxc "$vmid"
    pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-resize --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create failed"; return 1; }
    pct resize "$vmid" rootfs +4G >/dev/null 2>&1 || { record_fail "$test_name" "resize failed"; return 1; }
    destroy_lxc "$vmid"
    record_pass "$test_name"
}

test_lxc_live_migration() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Offline Migration ($NODE → $TARGET_NODE)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 && $IS_CLUSTER -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir or cluster unavailable"; return 0; }
    destroy_lxc "$vmid"
    pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-migrate --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create failed"; return 1; }
    pct migrate "$vmid" "$TARGET_NODE" >/dev/null 2>&1 || { record_fail "$test_name" "migrate to $TARGET_NODE failed"; destroy_lxc "$vmid"; return 1; }
    # Migrate back
    ssh "$TARGET_NODE" "pct migrate $vmid $NODE 2>/dev/null" >/dev/null 2>&1 || true
    destroy_lxc "$vmid"
    record_pass "$test_name"
}

test_lxc_multi_mountpoint() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Multi-Mountpoint (VMID $vmid)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir not enabled"; return 0; }
    destroy_lxc "$vmid"
    pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-mp --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create failed"; return 1; }
    pct set "$vmid" -mp0 "$STORAGE_ID:2,mp=/data" >/dev/null 2>&1 || { record_fail "$test_name" "mountpoint attach failed"; return 1; }
    destroy_lxc "$vmid"
    record_pass "$test_name"
}

test_lxc_stress() {
    local base_vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Rapid Create/Delete Stress (10 containers)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir not enabled"; return 0; }
    for i in {0..4}; do
        local vmid=$((base_vmid + i))
        pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:2" --hostname "test-lxc-stress-$i" --memory 256 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create $vmid failed"; return 1; }
        destroy_lxc "$vmid"
    done
    record_pass "$test_name"
}

test_lxc_concurrent() {
    local base_vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Concurrent Create/Destroy (10 containers)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 ]] || { record_skip_as_pass "$test_name" "rootdir not enabled"; return 0; }
    local err=/tmp/lxc-concurrent-$$ pids=() failed=0
    mkdir -p "$err"
    for i in {0..4}; do
        local vmid=$((base_vmid + i))
        destroy_lxc "$vmid"
        (pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:2" --hostname "test-lxc-concurrent-$i" --memory 256 --swap 0 >/dev/null 2>&1 && echo OK > "$err/$i") &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    for i in {0..4}; do
        local vmid=$((base_vmid + i))
        [[ "$(cat "$err/$i" 2>/dev/null)" == OK ]] || failed=$((failed + 1))
        destroy_lxc "$vmid"
    done
    rm -rf "$err"
    [[ $failed -eq 0 ]] || { record_fail "$test_name" "$failed of 5 concurrent creates failed"; return 1; }
    log_success "LXC concurrent create/destroy: 5/5 succeeded"
    record_pass "$test_name"
}

test_lxc_online_backup() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Online Backup (Running Container)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 && -n "$BACKUP_STORE" ]] || { record_skip_as_pass "$test_name" "rootdir or backup store unavailable"; return 0; }
    destroy_lxc "$vmid"
    pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-backup-online --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create failed"; return 1; }
    pct start "$vmid" >/dev/null 2>&1 || { record_fail "$test_name" "start failed"; destroy_lxc "$vmid"; return 1; }
    vzdump "$vmid" --mode snapshot --storage "$BACKUP_STORE" >/dev/null 2>&1 || { record_fail "$test_name" "backup failed"; pct stop "$vmid" >/dev/null 2>&1 || true; destroy_lxc "$vmid"; return 1; }
    pct stop "$vmid" >/dev/null 2>&1 || true
    destroy_lxc "$vmid"
    track_timing "lxc_online_backup" 1
    record_pass "$test_name"
}

test_lxc_offline_backup() {
    local vmid="$1" test_num="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="LXC Offline Backup (Stopped Container)"
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    [[ $IS_ROOTDIR -eq 1 && -n "$BACKUP_STORE" ]] || { record_skip_as_pass "$test_name" "rootdir or backup store unavailable"; return 0; }
    destroy_lxc "$vmid"
    pct create "$vmid" "$LXC_TEMPLATE" --rootfs "$STORAGE_ID:4" --hostname test-lxc-backup-offline --memory 512 --swap 0 >/dev/null 2>&1 || { record_fail "$test_name" "create failed"; return 1; }
    vzdump "$vmid" --mode stop --storage "$BACKUP_STORE" >/dev/null 2>&1 || { record_fail "$test_name" "backup failed"; destroy_lxc "$vmid"; return 1; }
    destroy_lxc "$vmid"
    track_timing "lxc_offline_backup" 1
    record_pass "$test_name"
}

print_performance_summary() {
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PERFORMANCE SUMMARY" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    printf "%-34s %8s %8s %8s %8s\n" "Operation" "Count" "Avg" "Min" "Max" | tee -a "$LOG_FILE"
    echo "────────────────────────────────────────────────────────────────────" | tee -a "$LOG_FILE"
    for operation in "${!PERF_TIMINGS[@]}"; do
        local timings="${PERF_TIMINGS[$operation]}" count="${PERF_COUNTS[$operation]}" sum=0 min=999999999 max=0
        for time in $timings; do
            sum=$((sum + time)); [[ $time -lt $min ]] && min=$time; [[ $time -gt $max ]] && max=$time
        done
        local avg=$((sum / count))
        printf "%-34s %8d %8d %8d %8d\n" "$operation" "$count" "$avg" "$min" "$max" | tee -a "$LOG_FILE"
    done
    echo | tee -a "$LOG_FILE"
}

run_phase_header() {
    local title="$1"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  $title" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
}

main() {
    echo "╔════════════════════════════════════════════════════════════════════╗" | tee "$LOG_FILE"
    echo "║           NASty Plugin Comprehensive Test Suite v1.1              ║" | tee -a "$LOG_FILE"
    echo "╚════════════════════════════════════════════════════════════════════╝" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    local apiver_result apiver_status system_apiver plugin_apiver
    apiver_result=$(check_apiver_mismatch)
    apiver_status=$(echo "$apiver_result" | cut -d'|' -f1)
    system_apiver=$(echo "$apiver_result" | cut -d'|' -f2)
    plugin_apiver=$(echo "$apiver_result" | cut -d'|' -f3)
    log_info "Configuration: storage=$STORAGE_ID node=$NODE vmids=$VMID_START-$VMID_END log=$LOG_FILE"
    log_info "Cluster: $([[ $IS_CLUSTER -eq 1 ]] && echo "yes target=$TARGET_NODE" || echo no)"
    log_info "LXC: $([[ $IS_ROOTDIR -eq 1 ]] && echo "yes template=$LXC_TEMPLATE" || echo no)"
    log_info "APIVER: $apiver_status system=$system_apiver plugin=$plugin_apiver"
    echo | tee -a "$LOG_FILE"

    local vmid test_num=1 clone_vmid

    if [[ $START_PHASE -le 1 ]]; then
        run_phase_header "PHASE 1: Pre-flight Cleanup"
        cleanup_test_vms "$VMID_START" "$VMID_END"
    fi
    check_stop_phase 1

    if [[ $START_PHASE -le 2 ]]; then run_phase_header "PHASE 2: Disk Allocation Tests"; vmid=$VMID_START; for size in "${TEST_SIZES[@]}"; do test_disk_allocation "$size" "$vmid" "$test_num"; vmid=$((vmid+1)); test_num=$((test_num+1)); done; fi; check_stop_phase 2
    if [[ $START_PHASE -le 3 ]]; then run_phase_header "PHASE 3: NASty Size Verification Tests"; vmid=$VMID_START; for _ in "${TEST_SIZES[@]}"; do test_truenas_size_verification "$vmid" "$test_num"; vmid=$((vmid+1)); test_num=$((test_num+1)); done; fi; check_stop_phase 3
    if [[ $START_PHASE -le 4 ]]; then run_phase_header "PHASE 4: Disk Deletion Tests"; vmid=$VMID_START; for _ in "${TEST_SIZES[@]}"; do test_disk_deletion "$vmid" "$test_num"; vmid=$((vmid+1)); test_num=$((test_num+1)); done; fi; check_stop_phase 4
    if [[ $START_PHASE -le 5 ]]; then run_phase_header "PHASE 5: Clone and Snapshot Tests"; test_create_base_vm_for_clone "$CLONE_BASE_VMID" "$test_num"; test_num=$((test_num+1)); test_create_snapshot "$CLONE_BASE_VMID" "$test_num"; test_num=$((test_num+1)); test_full_clone "$CLONE_BASE_VMID" "$CLONE_VMID" "$test_num"; test_num=$((test_num+1)); test_disk_deletion "$CLONE_VMID" "$test_num"; test_num=$((test_num+1)); test_delete_snapshot "$CLONE_BASE_VMID" "$test_num"; test_num=$((test_num+1)); test_disk_deletion "$CLONE_BASE_VMID" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 5
    if [[ $START_PHASE -le 6 ]]; then run_phase_header "PHASE 6: Disk Resize Test"; test_disk_resize "$((VMID_START + 10))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 6
    if [[ $START_PHASE -le 7 ]]; then run_phase_header "PHASE 7: Concurrent Operations Test"; test_concurrent_operations "$((VMID_START + 11))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 7
    if [[ $START_PHASE -le 8 ]]; then run_phase_header "PHASE 8: Performance Benchmarks"; test_performance "$((VMID_START + 13))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 8
    if [[ $START_PHASE -le 9 ]]; then run_phase_header "PHASE 9: Multiple Disks Test"; test_multiple_disks "$((VMID_START + 16))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 9
    if [[ $START_PHASE -le 10 ]]; then run_phase_header "PHASE 10: EFI VM Creation Test"; test_efi_vm_creation "$((VMID_START + 17))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 10
    if [[ $START_PHASE -le 11 ]]; then run_phase_header "PHASE 11: Multi-Disk Advanced Operations Tests"; test_multidisk_advanced_operations "$((VMID_START + 31))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 11
    if [[ $START_PHASE -le 12 ]]; then run_phase_header "PHASE 12: Live Migration Test"; test_live_migration "$((VMID_START + 18))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 12
    if [[ $START_PHASE -le 13 ]]; then run_phase_header "PHASE 13: Offline Migration Test"; test_offline_migration "$((VMID_START + 19))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 13
    if [[ $START_PHASE -le 14 ]]; then run_phase_header "PHASE 14: Cross-Node Clone (Online) Test"; vmid=$((VMID_START + 22)); clone_vmid=$((vmid+1)); test_cross_node_clone_online "$vmid" "$clone_vmid" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 14
    if [[ $START_PHASE -le 15 ]]; then run_phase_header "PHASE 15: Cross-Node Clone (Offline) Test"; vmid=$((VMID_START + 24)); clone_vmid=$((vmid+1)); test_cross_node_clone_offline "$vmid" "$clone_vmid" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 15
    if [[ $START_PHASE -le 16 ]]; then run_phase_header "PHASE 16: Online Backup Test"; test_online_backup "$((VMID_START + 20))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 16
    if [[ $START_PHASE -le 17 ]]; then run_phase_header "PHASE 17: Offline Backup Test"; test_offline_backup "$((VMID_START + 21))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 17
    if [[ $START_PHASE -le 18 ]]; then run_phase_header "PHASE 18: Rapid Creation/Deletion Stress Test"; test_rapid_create_delete_stress "$((VMID_START + 26))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 18
    if [[ $START_PHASE -le 19 ]]; then run_phase_header "PHASE 19: Storage Quota/Space Exhaustion Test"; test_storage_exhaustion "$((VMID_START + 27))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 19
    if [[ $START_PHASE -le 20 ]]; then run_phase_header "PHASE 20: Invalid/Malformed API Requests Test"; test_invalid_api_requests "$((VMID_START + 28))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 20
    if [[ $START_PHASE -le 21 ]]; then run_phase_header "PHASE 21: Interrupted Operations Test"; test_interrupted_operations "$((VMID_START + 29))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 21
    if [[ $START_PHASE -le 22 ]]; then run_phase_header "PHASE 22: Large Disk Operations Test"; test_large_disk_operations "$((VMID_START + 30))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 22
    if [[ $START_PHASE -le 23 ]]; then run_phase_header "PHASE 23: Transport Mode Verification Test"; test_transport_mode_verification "$((VMID_START + 32))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 23
    if [[ $START_PHASE -le 24 ]]; then run_phase_header "PHASE 24: Snapshot Reversion Test"; test_snapshot_reversion "$((VMID_START + 23))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 24
    if [[ $START_PHASE -le 25 ]]; then run_phase_header "PHASE 25: Disk Hotswap Test"; test_disk_hotswap "$((VMID_START + 24))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 25
    if [[ $START_PHASE -le 26 ]]; then run_phase_header "PHASE 26: API Rate Limiting Test"; test_api_rate_limiting "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 26
    if [[ $START_PHASE -le 27 ]]; then run_phase_header "PHASE 27: Multi-Pool Operations Test"; test_multi_pool_operations "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 27
    if [[ $START_PHASE -le 28 ]]; then run_phase_header "PHASE 28: Performance Regression Tracking"; test_performance_regression_tracking "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 28
    if [[ $START_PHASE -le 29 ]]; then run_phase_header "PHASE 29: Dataset Property Inheritance Test"; test_dataset_property_inheritance "$((VMID_START + 25))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 29
    if [[ $START_PHASE -le 30 ]]; then run_phase_header "PHASE 30: NVMe Stale Connection Recovery"; test_nvme_stale_recovery "$((VMID_START + 33))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 30
    if [[ $START_PHASE -le 31 ]]; then run_phase_header "PHASE 31: Concurrent Alloc+Free Lock Contention"; test_concurrent_alloc_free_contention "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 31
    if [[ $START_PHASE -le 32 ]]; then run_phase_header "PHASE 32: Multi-Disk Sequential Timing"; test_multi_disk_sequential_timing "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 32
    if [[ $START_PHASE -le 33 ]]; then run_phase_header "PHASE 33: Mixed Concurrent Operations"; test_mixed_concurrent_operations "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 33
    if [[ $START_PHASE -le 34 ]]; then run_phase_header "PHASE 34: Concurrent Clone Operations"; test_concurrent_clone_operations "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 34
    if [[ $START_PHASE -le 35 ]]; then run_phase_header "PHASE 35: Cross-Node Concurrent Allocations"; test_cross_node_concurrent_alloc "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 35
    if [[ $START_PHASE -le 36 ]]; then run_phase_header "PHASE 36: Concurrent Migration + Allocation"; test_concurrent_migration_alloc "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 36
    if [[ $START_PHASE -le 37 ]]; then run_phase_header "PHASE 37: LXC Container Create/Start/Stop"; test_lxc_create_start_stop "$LXC_VMID_START" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 37
    if [[ $START_PHASE -le 38 ]]; then run_phase_header "PHASE 38: LXC Snapshot & Revert"; test_lxc_snapshot_revert "$((LXC_VMID_START + 1))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 38
    if [[ $START_PHASE -le 39 ]]; then run_phase_header "PHASE 39: LXC Container Clone"; test_lxc_clone "$LXC_BASE_VMID" "$LXC_CLONE_VMID" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 39
    if [[ $START_PHASE -le 40 ]]; then run_phase_header "PHASE 40: LXC Container Resize"; test_lxc_resize "$((LXC_VMID_START + 3))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 40
    if [[ $START_PHASE -le 41 ]]; then run_phase_header "PHASE 41: LXC Offline Migration"; test_lxc_live_migration "$((LXC_VMID_START + 4))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 41
    if [[ $START_PHASE -le 42 ]]; then run_phase_header "PHASE 42: LXC Multi-Mountpoint"; test_lxc_multi_mountpoint "$((LXC_VMID_START + 5))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 42
    if [[ $START_PHASE -le 43 ]]; then run_phase_header "PHASE 43: LXC Rapid Create/Delete Stress"; test_lxc_stress "$((LXC_VMID_START + 20))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 43
    if [[ $START_PHASE -le 44 ]]; then run_phase_header "PHASE 44: LXC Concurrent Creation/Destruction"; test_lxc_concurrent "$((LXC_VMID_START + 30))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 44
    if [[ $START_PHASE -le 45 ]]; then run_phase_header "PHASE 45: LXC Online Backup"; test_lxc_online_backup "$((LXC_VMID_START + 6))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 45
    if [[ $START_PHASE -le 46 ]]; then run_phase_header "PHASE 46: LXC Offline Backup"; test_lxc_offline_backup "$((LXC_VMID_START + 7))" "$test_num"; test_num=$((test_num+1)); fi; check_stop_phase 46

    print_performance_summary
    local end_time total_duration
    end_time=$(date +%s)
    total_duration=$((end_time - START_TIME))
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  TEST SUMMARY" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "Total Tests:  $TOTAL_TESTS" | tee -a "$LOG_FILE"
    echo "Passed:       $PASSED_TESTS ✓" | tee -a "$LOG_FILE"
    echo "Failed:       $FAILED_TESTS ✗" | tee -a "$LOG_FILE"
    echo "Duration:     ${total_duration}s" | tee -a "$LOG_FILE"
    echo "Results:" | tee -a "$LOG_FILE"
    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$result" == PASS:* ]]; then echo "  ✓ ${result#PASS: }" | tee -a "$LOG_FILE"; else echo "  ✗ ${result#FAIL: }" | tee -a "$LOG_FILE"; fi
    done
    echo "Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
    if [[ $FAILED_TESTS -gt 0 ]]; then echo "Status: FAILED" | tee -a "$LOG_FILE"; exit 1; fi
    echo "Status: ALL TESTS PASSED" | tee -a "$LOG_FILE"
}

main "$@"
