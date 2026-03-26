#!/usr/bin/env bash
# =============================================================================
# 02-provision-vm.sh — Clone template and provision a new Swarm VM
#
# Usage:
#   ./02-provision-vm.sh --name <vmname> [OPTIONS]
#
# Options:
#   --name          <name>       VM hostname (required)
#   --template-id   <id>         Source template VMID (default: 9000)
#   --vmid          <id>         Override VMID (default: auto-assign next free)
#   --vlan          <tag>        Network VLAN tag (default: 85)
#   --role          <worker|manager>  Node role — sets default VLAN if not explicit
#   --bridge        <bridge>     Network bridge (default: vmbr0)
#   --storage       <pool>       Proxmox storage pool (default: local-zfs)
#   --memory        <mb>         RAM in MB (default: 4096)
#   --cores         <n>          vCPUs (default: 4)
#   --snippets-dir  <path>       Proxmox snippets dir (default: /var/lib/vz/snippets)
#   --ssh-key-file  <path>       SSH public key (default: /root/.ssh/homelab_ed25519.pub)
#   --registry-dir  <path>       VM registry output dir (default: /root/vm-registry)
#   --volume        <name:size>  Create + attach extra ZFS zvol (repeatable)
#   --zfs-pool      <pool>       ZFS pool for virtiofs datasets (default: rpool/data)
#   --no-virtiofs                Skip attaching virtiofs mounts
#   --no-autostart               Don't start VM after provisioning
#   --no-cleanup                 Keep VM on failure (for debugging)
#   --first-manager              Mark VM as swarm initialiser in registry
#   --agent-timeout <sec>        Seconds to wait for guest agent IP (default: 120)
#   --fqdn-suffix   <domain>     Domain suffix for FQDN (default: home.arpa)
#   -h, --help                   Show this help
#
# virtiofs datasets attached (from --zfs-pool):
#   docker-data  → /mnt/docker-data   (Docker data-root)
#   docker-tsdb  → /mnt/docker-tsdb   (time-series DBs)
#   docker-db    → /mnt/docker-db     (relational DBs)
#   docker-swarm → /mnt/docker-swarm  (shared configs + stack files)
#
# Output:
#   /root/vm-registry/<vmname>.json  — VMID, IP, MAC, role, timestamps
#
# Must run as root on a Proxmox node.
# =============================================================================

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/proxmox-swarm"
LOG_FILE="${LOG_DIR}/02-provision-vm-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}"

log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] $*"
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}"
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }
die()   { error "$@"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────────────────────
VM_NAME=""
TEMPLATE_ID=9000
VMID=""
VLAN_TAG=""          # resolved after --role is known
ROLE="worker"
BRIDGE="vmbr0"
STORAGE="local-zfs"
MEMORY=4096
CORES=4
SNIPPETS_DIR="/var/lib/vz/snippets"
SSH_KEY_FILE="/root/.ssh/homelab_ed25519.pub"
REGISTRY_DIR="/root/vm-registry"
EXTRA_VOLUMES=()     # array of "name:size" strings
ZFS_POOL="rpool/data"
NO_VIRTIOFS=false
NO_AUTOSTART=false
NO_CLEANUP=false
FIRST_MANAGER=false
AGENT_TIMEOUT=120
FQDN_SUFFIX="home.arpa"

# virtiofs datasets and their guest mount points
VIRTIOFS_DATASETS=(
    "docker-data:/mnt/docker-data"
    "docker-tsdb:/mnt/docker-tsdb"
    "docker-db:/mnt/docker-db"
    "docker-swarm:/mnt/docker-swarm"
)

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -50
    exit 0
}

parse_args() {
    [[ $# -eq 0 ]] && { usage; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)           VM_NAME="$2";        shift 2 ;;
            --template-id)    TEMPLATE_ID="$2";    shift 2 ;;
            --vmid)           VMID="$2";           shift 2 ;;
            --vlan)           VLAN_TAG="$2";       shift 2 ;;
            --role)           ROLE="$2";           shift 2 ;;
            --bridge)         BRIDGE="$2";         shift 2 ;;
            --storage)        STORAGE="$2";        shift 2 ;;
            --memory)         MEMORY="$2";         shift 2 ;;
            --cores)          CORES="$2";          shift 2 ;;
            --snippets-dir)   SNIPPETS_DIR="$2";   shift 2 ;;
            --ssh-key-file)   SSH_KEY_FILE="$2";   shift 2 ;;
            --registry-dir)   REGISTRY_DIR="$2";   shift 2 ;;
            --volume)         EXTRA_VOLUMES+=("$2"); shift 2 ;;
            --zfs-pool)       ZFS_POOL="$2";       shift 2 ;;
            --no-virtiofs)    NO_VIRTIOFS=true;    shift   ;;
            --no-autostart)   NO_AUTOSTART=true;   shift   ;;
            --no-cleanup)     NO_CLEANUP=true;     shift   ;;
            --first-manager)  FIRST_MANAGER=true;  shift   ;;
            --agent-timeout)  AGENT_TIMEOUT="$2";  shift 2 ;;
            --fqdn-suffix)    FQDN_SUFFIX="$2";    shift 2 ;;
            -h|--help)        usage ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    [[ -n "${VM_NAME}" ]] || die "--name is required"

    # Validate role
    case "${ROLE}" in
        worker|manager) ;;
        *) die "--role must be 'worker' or 'manager'" ;;
    esac

    # Default VLAN by role if not explicitly set
    if [[ -z "${VLAN_TAG}" ]]; then
        [[ "${ROLE}" == "manager" ]] && VLAN_TAG=60 || VLAN_TAG=85
    fi

    # --first-manager implies manager role
    if ${FIRST_MANAGER} && [[ "${ROLE}" != "manager" ]]; then
        warn "--first-manager set but --role is not manager; setting role=manager"
        ROLE="manager"
        [[ "${VLAN_TAG}" == "85" ]] && VLAN_TAG=60  # re-apply default if user didn't override
    fi
}

# ── Cleanup / trap ────────────────────────────────────────────────────────────
CREATED_VMID=""
CREATED_ZVOLS=()

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]] && [[ -n "${CREATED_VMID}" ]]; then
        if ${NO_CLEANUP}; then
            warn "Failure — --no-cleanup set, leaving VM ${CREATED_VMID} intact"
        else
            warn "Failure — destroying VM ${CREATED_VMID}"
            qm stop  "${CREATED_VMID}" 2>/dev/null || true
            qm destroy "${CREATED_VMID}" --purge 2>/dev/null \
                || warn "VM destroy failed (non-fatal)"
            for zvol in "${CREATED_ZVOLS[@]:-}"; do
                [[ -z "${zvol}" ]] && continue
                warn "Destroying zvol ${zvol}"
                zfs destroy "${zvol}" 2>/dev/null || warn "zfs destroy ${zvol} failed (non-fatal)"
            done
        fi
    fi
    if [[ $exit_code -ne 0 ]]; then
        error "Script failed (exit ${exit_code}). Log: ${LOG_FILE}"
    else
        info "Done. Log: ${LOG_FILE}"
    fi
}
trap cleanup EXIT

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
    info "Checking prerequisites..."
    [[ $EUID -eq 0 ]] || die "Must run as root"

    local missing=()
    for cmd in qm pvesh zfs; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"

    [[ -f "${SSH_KEY_FILE}" ]] || die "SSH public key not found: ${SSH_KEY_FILE}"
    [[ -d "${SNIPPETS_DIR}" ]] || die "Snippets dir not found: ${SNIPPETS_DIR} (run 01-create-template.sh first)"

    # Verify template exists and is a template
    qm config "${TEMPLATE_ID}" &>/dev/null \
        || die "Template VMID ${TEMPLATE_ID} not found. Run 01-create-template.sh first."
    qm config "${TEMPLATE_ID}" | grep -q "template: 1" \
        || die "VMID ${TEMPLATE_ID} exists but is not a template"

    mkdir -p "${REGISTRY_DIR}"
    info "Prerequisites OK"
}

# ── VMID auto-assign ──────────────────────────────────────────────────────────
resolve_vmid() {
    if [[ -n "${VMID}" ]]; then
        qm status "${VMID}" &>/dev/null \
            && die "VMID ${VMID} is already in use"
        info "Using specified VMID: ${VMID}"
        return
    fi

    info "Auto-assigning next free VMID..."
    # Collect used VMIDs
    local used
    used="$(pvesh get /nodes/localhost/qemu --output-format=json 2>/dev/null \
        | grep -oP '"vmid":\K[0-9]+' | sort -n)"

    # Start scanning from 100, skip anything ≥ 9000 (template range)
    local candidate=100
    while true; do
        if [[ "${candidate}" -ge 9000 ]]; then
            die "Exhausted VMID range below 9000"
        fi
        if ! echo "${used}" | grep -qx "${candidate}"; then
            VMID="${candidate}"
            info "Auto-assigned VMID: ${VMID}"
            return
        fi
        (( candidate++ ))
    done
}

# ── Per-VM user cloud-init snippet ────────────────────────────────────────────
write_user_snippet() {
    local snippet_name="user-${VM_NAME}.yaml"
    local snippet_path="${SNIPPETS_DIR}/${snippet_name}"
    local fqdn="${VM_NAME}.${FQDN_SUFFIX}"

    info "Writing per-VM user snippet: ${snippet_path}"
    cat > "${snippet_path}" <<EOF
#cloud-config
# Per-VM user snippet for ${VM_NAME}
# Generated by 02-provision-vm.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

hostname: ${VM_NAME}
fqdn: ${fqdn}
manage_etc_hosts: true
preserve_hostname: false
EOF
    info "User snippet written"
    echo "${snippet_name}"
}

# ── Extra ZFS zvols ───────────────────────────────────────────────────────────
# Creates zvols and returns a list of "disk_index:zvol_path" pairs written
# to EXTRA_DISK_ARGS array for attachment after clone.
EXTRA_DISK_ARGS=()

create_extra_volumes() {
    [[ ${#EXTRA_VOLUMES[@]} -eq 0 ]] && return

    info "Creating ${#EXTRA_VOLUMES[@]} extra volume(s)..."
    local disk_idx=1  # scsi0 is root; start additional at scsi1

    for vol_spec in "${EXTRA_VOLUMES[@]}"; do
        local vol_name vol_size
        vol_name="$(echo "${vol_spec}" | cut -d: -f1)"
        vol_size="$(echo "${vol_spec}" | cut -d: -f2)"
        [[ -n "${vol_name}" && -n "${vol_size}" ]] \
            || die "Invalid --volume spec '${vol_spec}'. Expected name:size (e.g. plex-config:20G)"

        local zvol_path="${ZFS_POOL}/vm-${VMID}-${vol_name}"

        if zfs list "${zvol_path}" &>/dev/null; then
            warn "zvol ${zvol_path} already exists — reusing"
        else
            info "Creating zvol ${zvol_path} (${vol_size})..."
            zfs create -V "${vol_size}" "${zvol_path}" \
                || die "Failed to create zvol ${zvol_path}"
            CREATED_ZVOLS+=("${zvol_path}")
        fi

        EXTRA_DISK_ARGS+=("scsi${disk_idx}:/dev/zvol/${zvol_path},discard=on")
        (( disk_idx++ ))
    done
}

# ── Clone ─────────────────────────────────────────────────────────────────────
clone_template() {
    info "Cloning template ${TEMPLATE_ID} → VM ${VMID} (${VM_NAME})..."
    CREATED_VMID="${VMID}"

    qm clone "${TEMPLATE_ID}" "${VMID}" \
        --name "${VM_NAME}" \
        --full \
        --storage "${STORAGE}" \
        || die "qm clone failed"

    info "Clone complete"
}

# ── Configure VM ─────────────────────────────────────────────────────────────
configure_vm() {
    local user_snippet_name="$1"
    local ssh_key
    ssh_key="$(cat "${SSH_KEY_FILE}")"

    info "Configuring VM ${VMID}..."

    # Network: update VLAN tag (template is tagged 60; workers need 85 or custom)
    qm set "${VMID}" \
        --net0 "virtio,bridge=${BRIDGE},tag=${VLAN_TAG}" \
        || die "Failed to set network config"

    # Cloud-init: user, SSH key, hostname, cicustom user+vendor
    qm set "${VMID}" \
        --ciuser ubuntu \
        --sshkeys <(echo "${ssh_key}") \
        --ipconfig0 ip=dhcp \
        --cicustom "user=local:snippets/${user_snippet_name},vendor=local:snippets/base-vendor.yaml" \
        || die "Failed to set cloud-init config"

    # Memory / cores (may differ from template defaults)
    qm set "${VMID}" \
        --memory "${MEMORY}" \
        --cores "${CORES}" \
        || die "Failed to set resources"

    # Extra disks
    for disk_arg in "${EXTRA_DISK_ARGS[@]:-}"; do
        [[ -z "${disk_arg}" ]] && continue
        local slot="${disk_arg%%:*}"
        local path_spec="${disk_arg#*:}"
        info "Attaching extra disk: ${slot} → ${path_spec}"
        qm set "${VMID}" --"${slot}" "${path_spec}" \
            || die "Failed to attach disk ${slot}"
    done

    # virtiofs mounts
    if ! ${NO_VIRTIOFS}; then
        attach_virtiofs
    else
        info "Skipping virtiofs mounts (--no-virtiofs)"
    fi

    info "VM ${VMID} configured"
}

# ── virtiofs ──────────────────────────────────────────────────────────────────
# Proxmox exposes virtiofs shares via the 'virtio-fs' feature in qm config.
# Each share maps a host ZFS dataset path to a guest tag that fstab uses.
# pve-virtiofsd must be available (Proxmox 8+).
attach_virtiofs() {
    info "Attaching virtiofs mounts..."
    local idx=0
    for entry in "${VIRTIOFS_DATASETS[@]}"; do
        local dataset="${entry%%:*}"
        local guest_mount="${entry#*:}"
        local host_path="/${ZFS_POOL}/${dataset}"
        local tag="vfs-${dataset}"

        # Ensure the ZFS dataset exists on the host
        if ! zfs list "${ZFS_POOL}/${dataset}" &>/dev/null; then
            info "ZFS dataset ${ZFS_POOL}/${dataset} not found — creating..."
            zfs create -p "${ZFS_POOL}/${dataset}" \
                || die "Failed to create ZFS dataset ${ZFS_POOL}/${dataset}"
        fi

        info "  ${tag}: ${host_path} → ${guest_mount}"
        qm set "${VMID}" \
            --virtiofs${idx} "source=${host_path},tag=${tag}" \
            || die "Failed to attach virtiofs${idx} (${tag})"
        (( idx++ ))
    done
    info "virtiofs mounts attached (${idx} shares)"
}

# ── Start VM + wait for IP ────────────────────────────────────────────────────
VM_IP=""
VM_MAC=""

start_and_get_ip() {
    if ${NO_AUTOSTART}; then
        info "Skipping VM start (--no-autostart)"
        return
    fi

    info "Starting VM ${VMID}..."
    qm start "${VMID}" || die "qm start failed"

    info "Waiting for guest agent to report IP (timeout: ${AGENT_TIMEOUT}s)..."
    local elapsed=0
    local interval=5
    while [[ ${elapsed} -lt ${AGENT_TIMEOUT} ]]; do
        local agent_out
        agent_out="$(qm agent "${VMID}" network-get-interfaces 2>/dev/null)" || true

        if [[ -n "${agent_out}" ]]; then
            # Extract first non-loopback IPv4
            VM_IP="$(echo "${agent_out}" \
                | grep -oP '"ip-address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
                | grep -v '^127\.' | head -1)" || true

            if [[ -n "${VM_IP}" ]]; then
                info "Guest IP: ${VM_IP}"
                # Extract MAC for the first interface
                VM_MAC="$(qm config "${VMID}" \
                    | grep '^net0:' \
                    | grep -oP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')" || true
                info "Guest MAC: ${VM_MAC:-unknown}"
                return
            fi
        fi

        sleep "${interval}"
        (( elapsed += interval ))
        info "  ...waiting (${elapsed}s / ${AGENT_TIMEOUT}s)"
    done

    die "Timed out waiting for guest agent IP after ${AGENT_TIMEOUT}s. VM may still be booting; check with 'qm agent ${VMID} network-get-interfaces'"
}

# ── Registry ──────────────────────────────────────────────────────────────────
write_registry() {
    local registry_file="${REGISTRY_DIR}/${VM_NAME}.json"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    info "Writing registry: ${registry_file}"
    cat > "${registry_file}" <<EOF
{
  "name":          "${VM_NAME}",
  "vmid":          ${VMID},
  "role":          "${ROLE}",
  "ip":            "${VM_IP:-}",
  "mac":           "${VM_MAC:-}",
  "vlan":          ${VLAN_TAG},
  "template_id":   ${TEMPLATE_ID},
  "first_manager": ${FIRST_MANAGER},
  "provisioned_at": "${now}",
  "log":           "${LOG_FILE}"
}
EOF
    info "Registry written"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    info ""
    info "========================================================"
    info " VM Provisioned Successfully"
    info "========================================================"
    info "  Name       : ${VM_NAME}"
    info "  VMID       : ${VMID}"
    info "  Role       : ${ROLE}"
    info "  VLAN       : ${VLAN_TAG}"
    info "  IP         : ${VM_IP:-<not started>}"
    info "  MAC        : ${VM_MAC:-<not started>}"
    info "  Registry   : ${REGISTRY_DIR}/${VM_NAME}.json"
    if [[ ${#EXTRA_VOLUMES[@]} -gt 0 ]]; then
        info "  Extra vols : ${EXTRA_VOLUMES[*]}"
    fi
    info ""
    if ! ${NO_AUTOSTART} && [[ -n "${VM_IP}" ]]; then
        info "Next step:"
        if ${FIRST_MANAGER}; then
            info "  ./03-post-boot.sh ${VM_NAME} --first-manager --role manager"
        else
            info "  ./03-post-boot.sh ${VM_NAME} --join-swarm --role ${ROLE}"
        fi
    elif ${NO_AUTOSTART}; then
        info "Start the VM manually with: qm start ${VMID}"
    fi
    info "========================================================"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    LOG_FILE="${LOG_DIR}/02-provision-${VM_NAME}-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "${LOG_DIR}"

    info "========================================================"
    info " 02-provision-vm.sh"
    info " VM name   : ${VM_NAME}"
    info " Role      : ${ROLE}"
    info " VLAN      : ${VLAN_TAG}"
    info " Template  : ${TEMPLATE_ID}"
    info " Log file  : ${LOG_FILE}"
    info "========================================================"

    check_prerequisites
    resolve_vmid
    create_extra_volumes
    local user_snippet_name
    user_snippet_name="$(write_user_snippet)"
    clone_template
    configure_vm "${user_snippet_name}"
    start_and_get_ip
    write_registry
    # Successful — clear cleanup VMID
    CREATED_VMID=""
    CREATED_ZVOLS=()
    print_summary
}

main "$@"
