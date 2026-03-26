#!/usr/bin/env bash
# =============================================================================
# 01-create-template.sh — Build Ubuntu 24.04 cloud-init template for Proxmox
#
# PROBLEM SOLVED: Ubuntu 24.04 cloud images boot with DataSourceNoCloud by
# default. On Proxmox, this causes cloud-init to read only the CD-ROM seed and
# ignore cicustom vendor configs entirely — runcmd never runs even when cicustom
# is correctly set.
#
# FIX: Inject /etc/cloud/cloud.cfg.d/99-pve.cfg into the source .img via NBD
# BEFORE importing into Proxmox. The file must exist on disk before first boot;
# cloud-init cannot write it itself (chicken-and-egg problem).
#
# Usage:
#   ./01-create-template.sh [OPTIONS]
#
# Options:
#   --template-id   <id>       VMID for the template (default: 9000)
#   --template-name <name>     VM name for the template (default: ubuntu-2404-tmpl)
#   --storage       <pool>     Proxmox storage pool (default: rpool/data -> local-zfs)
#   --bridge        <bridge>   Network bridge (default: vmbr0)
#   --vlan          <tag>      VLAN tag on template NIC (default: 60)
#   --memory        <mb>       RAM in MB (default: 2048)
#   --cores         <n>        vCPUs (default: 2)
#   --disk-size     <size>     Root disk size after resize (default: 20G)
#   --image-url     <url>      Cloud image URL (default: Ubuntu 24.04 noble)
#   --image-dir     <path>     Where to cache downloaded image (default: /var/lib/vz/template/iso)
#   --snippets-dir  <path>     Proxmox snippets directory (default: /var/lib/vz/snippets)
#   --ssh-key-file  <path>     SSH public key to embed (default: /root/.ssh/homelab_ed25519.pub)
#   --no-cleanup               Keep partial VM on failure (for debugging)
#   --force                    Re-create template even if VMID already exists
#   -h, --help                 Show this help
#
# Requires: qm, pvesm, nbd (qemu-utils), virt-customize (libguestfs-tools) OR
#           manual nbd mount. Script uses nbd + mount (no libguestfs needed).
# Must run as root on a Proxmox node.
# =============================================================================

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/proxmox-swarm"
LOG_FILE="${LOG_DIR}/01-create-template-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}"

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${msg}"
    echo "${line}"
    echo "${line}" >> "${LOG_FILE}"
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }
die()   { error "$@"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────────────────────
TEMPLATE_ID=9000
TEMPLATE_NAME="ubuntu-2404-tmpl"
STORAGE="local-zfs"
BRIDGE="vmbr0"
VLAN_TAG=60
MEMORY=2048
CORES=2
DISK_SIZE="20G"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_CHECKSUM_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
IMAGE_DIR="/var/lib/vz/template/iso"
SNIPPETS_DIR="/var/lib/vz/snippets"
SSH_KEY_FILE="/root/.ssh/homelab_ed25519.pub"
NO_CLEANUP=false
FORCE=false

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | grep -E '^\# ' | sed 's/^# //' | head -40
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template-id)   TEMPLATE_ID="$2";   shift 2 ;;
            --template-name) TEMPLATE_NAME="$2"; shift 2 ;;
            --storage)       STORAGE="$2";       shift 2 ;;
            --bridge)        BRIDGE="$2";        shift 2 ;;
            --vlan)          VLAN_TAG="$2";      shift 2 ;;
            --memory)        MEMORY="$2";        shift 2 ;;
            --cores)         CORES="$2";         shift 2 ;;
            --disk-size)     DISK_SIZE="$2";     shift 2 ;;
            --image-url)     IMAGE_URL="$2";     shift 2 ;;
            --image-dir)     IMAGE_DIR="$2";     shift 2 ;;
            --snippets-dir)  SNIPPETS_DIR="$2";  shift 2 ;;
            --ssh-key-file)  SSH_KEY_FILE="$2";  shift 2 ;;
            --no-cleanup)    NO_CLEANUP=true;    shift   ;;
            --force)         FORCE=true;         shift   ;;
            -h|--help)       usage ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

# ── Cleanup / trap ────────────────────────────────────────────────────────────
NBD_DEVICE=""
MOUNT_POINT=""
CLEANUP_VMID=""

cleanup() {
    local exit_code=$?

    # Unmount and disconnect NBD regardless
    if [[ -n "${MOUNT_POINT}" ]] && mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        info "Unmounting ${MOUNT_POINT}"
        umount "${MOUNT_POINT}" || warn "umount failed (non-fatal)"
        MOUNT_POINT=""
    fi
    if [[ -n "${NBD_DEVICE}" ]]; then
        info "Disconnecting NBD device ${NBD_DEVICE}"
        qemu-nbd --disconnect "${NBD_DEVICE}" 2>/dev/null || warn "nbd disconnect failed (non-fatal)"
        NBD_DEVICE=""
    fi

    if [[ $exit_code -ne 0 ]] && [[ -n "${CLEANUP_VMID}" ]]; then
        if ${NO_CLEANUP}; then
            warn "Failure detected but --no-cleanup set; leaving VM ${CLEANUP_VMID} intact"
        else
            warn "Failure detected; destroying VM ${CLEANUP_VMID}"
            qm destroy "${CLEANUP_VMID}" --purge 2>/dev/null || warn "VM destroy failed (non-fatal)"
        fi
    fi

    if [[ $exit_code -ne 0 ]]; then
        error "Script failed (exit ${exit_code}). Log: ${LOG_FILE}"
    else
        info "Done. Log: ${LOG_FILE}"
    fi
}
trap cleanup EXIT

# ── Prerequisite checks ───────────────────────────────────────────────────────
check_prerequisites() {
    info "Checking prerequisites..."
    [[ $EUID -eq 0 ]] || die "Must run as root"

    local missing=()
    for cmd in qm qemu-nbd modprobe sha256sum curl; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"

    [[ -f "${SSH_KEY_FILE}" ]] || die "SSH public key not found: ${SSH_KEY_FILE}"
    [[ -d "${SNIPPETS_DIR}" ]] || { mkdir -p "${SNIPPETS_DIR}"; info "Created snippets dir: ${SNIPPETS_DIR}"; }
    [[ -d "${IMAGE_DIR}" ]]    || { mkdir -p "${IMAGE_DIR}";    info "Created image dir: ${IMAGE_DIR}"; }

    info "Prerequisites OK"
}

# ── Image download ────────────────────────────────────────────────────────────
IMAGE_FILE=""

download_image() {
    local filename
    filename="$(basename "${IMAGE_URL}")"
    IMAGE_FILE="${IMAGE_DIR}/${filename}"
    local work_image="${IMAGE_DIR}/work-$(basename "${IMAGE_URL}")"

    info "Image URL:  ${IMAGE_URL}"
    info "Image path: ${IMAGE_FILE}"

    # Download checksum file
    local checksum_file="${IMAGE_DIR}/SHA256SUMS-noble"
    info "Downloading SHA256SUMS..."
    curl -fsSL "${IMAGE_CHECKSUM_URL}" -o "${checksum_file}" \
        || die "Failed to download checksum file from ${IMAGE_CHECKSUM_URL}"

    # Extract expected hash for this image
    local expected_hash
    expected_hash="$(grep "${filename}" "${checksum_file}" | awk '{print $1}')"
    [[ -n "${expected_hash}" ]] || die "Could not find checksum for ${filename} in SHA256SUMS"
    info "Expected SHA256: ${expected_hash}"

    # Check if existing download is valid
    if [[ -f "${IMAGE_FILE}" ]]; then
        info "Existing image found, verifying checksum..."
        local actual_hash
        actual_hash="$(sha256sum "${IMAGE_FILE}" | awk '{print $1}')"
        if [[ "${actual_hash}" == "${expected_hash}" ]]; then
            info "Checksum match — reusing cached image"
            return 0
        else
            warn "Checksum mismatch (got ${actual_hash}), re-downloading"
            rm -f "${IMAGE_FILE}"
        fi
    fi

    info "Downloading image (this may take a while)..."
    curl -fL --progress-bar "${IMAGE_URL}" -o "${IMAGE_FILE}" \
        || die "Download failed"

    info "Verifying downloaded image checksum..."
    local dl_hash
    dl_hash="$(sha256sum "${IMAGE_FILE}" | awk '{print $1}')"
    [[ "${dl_hash}" == "${expected_hash}" ]] \
        || die "Downloaded image checksum mismatch! Expected ${expected_hash}, got ${dl_hash}"
    info "Download verified OK"
}

# ── NBD injection of 99-pve.cfg ───────────────────────────────────────────────
# This is the core fix for DataSourceNoCloud.  We mount the raw image via NBD,
# then write 99-pve.cfg so it exists on disk before any Proxmox import or boot.
inject_cloud_cfg() {
    local src_image="$1"
    local work_image="${src_image%.img}-pve-patched.img"

    # Always work on a copy so the cached original stays pristine
    if [[ -f "${work_image}" ]]; then
        info "Patched work image already exists, removing and re-patching to ensure freshness"
        rm -f "${work_image}"
    fi

    info "Copying image to work copy: ${work_image}"
    cp "${src_image}" "${work_image}"

    # Load NBD kernel module
    info "Loading nbd kernel module..."
    modprobe nbd max_part=8 || die "Failed to load nbd module"

    # Find a free NBD device
    local nbd_dev=""
    for dev in /dev/nbd{0..15}; do
        if [[ -b "${dev}" ]] && ! lsblk "${dev}" --output NAME -n 2>/dev/null | grep -q .; then
            nbd_dev="${dev}"
            break
        fi
    done
    [[ -n "${nbd_dev}" ]] || die "No free NBD device found (checked /dev/nbd0-15)"
    NBD_DEVICE="${nbd_dev}"

    info "Connecting image to ${NBD_DEVICE}..."
    qemu-nbd --connect="${NBD_DEVICE}" "${work_image}" \
        || die "qemu-nbd connect failed"

    # Wait for kernel to settle and expose partitions
    sleep 2

    # Find the root partition (Ubuntu cloud images: partition 1 is the root)
    local root_part="${NBD_DEVICE}p1"
    if [[ ! -b "${root_part}" ]]; then
        # Some images expose as p1, some as the device itself if no partition table
        # Try detecting
        lsblk "${NBD_DEVICE}" --output NAME,FSTYPE -n 2>/dev/null | info "lsblk output:"
        die "Root partition ${root_part} not found. Check image format."
    fi

    MOUNT_POINT="$(mktemp -d /tmp/nbd-mount-XXXXXX)"
    info "Mounting ${root_part} at ${MOUNT_POINT}..."
    mount "${root_part}" "${MOUNT_POINT}" \
        || die "Failed to mount ${root_part}"

    # Write the datasource config
    local cfg_dir="${MOUNT_POINT}/etc/cloud/cloud.cfg.d"
    mkdir -p "${cfg_dir}"
    info "Writing 99-pve.cfg to image..."
    cat > "${cfg_dir}/99-pve.cfg" <<'EOF'
# Force cloud-init to prefer ConfigDrive (Proxmox cicustom) over NoCloud.
# Without this, Ubuntu 24.04 defaults to NoCloud on first boot and ignores
# cicustom vendor configs — runcmd never executes.
datasource_list:
  - ConfigDrive
  - NoCloud
  - None
EOF

    info "99-pve.cfg written:"
    cat "${cfg_dir}/99-pve.cfg" | while IFS= read -r line; do info "  ${line}"; done

    # Cleanup mount (trap will also handle this but let's be explicit)
    info "Unmounting ${MOUNT_POINT}..."
    umount "${MOUNT_POINT}"
    MOUNT_POINT=""

    info "Disconnecting NBD ${NBD_DEVICE}..."
    qemu-nbd --disconnect "${NBD_DEVICE}"
    NBD_DEVICE=""

    info "Image patched successfully: ${work_image}"
    IMAGE_FILE="${work_image}"
}

# ── Write vendor snippet ───────────────────────────────────────────────────────
write_vendor_snippet() {
    local snippet_path="${SNIPPETS_DIR}/base-vendor.yaml"
    info "Writing base-vendor.yaml to ${snippet_path}..."
    cat > "${snippet_path}" <<'EOF'
#cloud-config
# base-vendor.yaml — Proxmox vendor cloud-init snippet
#
# Intentionally minimal: install only what post-boot scripts need.
# Docker, swarm join, NFS mounts are all handled by 03-post-boot.sh
# for proper error handling and re-runnability.

package_update: true
package_upgrade: false

packages:
  - qemu-guest-agent
  - nfs-common
  - curl
  - fuse-overlayfs
  - jq

runcmd:
  - systemctl enable --now qemu-guest-agent
EOF
    info "Vendor snippet written"
}

# ── Proxmox VM creation ───────────────────────────────────────────────────────
create_vm() {
    info "Creating VM ${TEMPLATE_ID} (${TEMPLATE_NAME})..."
    CLEANUP_VMID="${TEMPLATE_ID}"

    local ssh_key
    ssh_key="$(cat "${SSH_KEY_FILE}")"

    # Create the VM shell
    qm create "${TEMPLATE_ID}" \
        --name "${TEMPLATE_NAME}" \
        --memory "${MEMORY}" \
        --cores "${CORES}" \
        --cpu cputype=host \
        --net0 virtio,bridge="${BRIDGE}",tag="${VLAN_TAG}" \
        --ostype l26 \
        --agent enabled=1 \
        --serial0 socket \
        --vga serial0 \
        --boot order=scsi0 \
        --scsihw virtio-scsi-pci \
        || die "qm create failed"

    info "Importing disk from ${IMAGE_FILE} into ${STORAGE}..."
    qm importdisk "${TEMPLATE_ID}" "${IMAGE_FILE}" "${STORAGE}" \
        || die "qm importdisk failed"

    # Attach the imported disk as scsi0
    info "Attaching disk..."
    qm set "${TEMPLATE_ID}" \
        --scsi0 "${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on" \
        || die "Failed to attach disk"

    # Resize root disk
    info "Resizing disk to ${DISK_SIZE}..."
    qm resize "${TEMPLATE_ID}" scsi0 "${DISK_SIZE}" \
        || die "qm resize failed"

    # Cloud-init drive
    info "Adding cloud-init drive..."
    qm set "${TEMPLATE_ID}" \
        --ide2 "${STORAGE}:cloudinit" \
        || die "Failed to add cloud-init drive"

    # Cloud-init user settings
    info "Configuring cloud-init user settings..."
    qm set "${TEMPLATE_ID}" \
        --ciuser ubuntu \
        --sshkeys <(echo "${ssh_key}") \
        --ipconfig0 ip=dhcp \
        || die "Failed to set cloud-init config"

    # Vendor snippet — points to our base-vendor.yaml
    info "Setting cicustom vendor snippet..."
    qm set "${TEMPLATE_ID}" \
        --cicustom "vendor=local:snippets/base-vendor.yaml" \
        || die "Failed to set cicustom"

    info "VM ${TEMPLATE_ID} configured"
}

# ── Convert to template ───────────────────────────────────────────────────────
convert_to_template() {
    info "Converting VM ${TEMPLATE_ID} to template..."
    qm template "${TEMPLATE_ID}" \
        || die "qm template failed"
    # Clear the VMID from cleanup — template creation succeeded
    CLEANUP_VMID=""
    info "Template created successfully"
}

# ── Verify ────────────────────────────────────────────────────────────────────
verify_template() {
    info "Verifying template..."
    local config
    config="$(qm config "${TEMPLATE_ID}" 2>/dev/null)" \
        || die "Cannot read VM ${TEMPLATE_ID} config — does it exist?"

    echo "${config}" | grep -q "template: 1" \
        || die "VM ${TEMPLATE_ID} exists but is NOT marked as a template"

    echo "${config}" | grep -q "cicustom" \
        || warn "cicustom not found in VM config — snippet may not be applied"

    echo "${config}" | grep -q "agent" \
        || warn "QEMU guest agent not found in VM config"

    info "Template ${TEMPLATE_ID} (${TEMPLATE_NAME}) verified OK"
    info ""
    info "Summary:"
    info "  Template VMID : ${TEMPLATE_ID}"
    info "  Template name : ${TEMPLATE_NAME}"
    info "  Storage       : ${STORAGE}"
    info "  Disk size     : ${DISK_SIZE}"
    info "  Network       : ${BRIDGE}, VLAN ${VLAN_TAG}"
    info "  Vendor snippet: ${SNIPPETS_DIR}/base-vendor.yaml"
    info "  SSH key       : ${SSH_KEY_FILE}"
    info ""
    info "Next step: ./02-provision-vm.sh --name <vmname> [--role worker|manager]"
}

# ── Handle pre-existing template ──────────────────────────────────────────────
handle_existing() {
    if qm status "${TEMPLATE_ID}" &>/dev/null; then
        if ${FORCE}; then
            warn "Template ${TEMPLATE_ID} already exists — --force set, destroying it"
            qm destroy "${TEMPLATE_ID}" --purge \
                || die "Failed to destroy existing VM ${TEMPLATE_ID}"
        else
            die "VMID ${TEMPLATE_ID} already exists. Use --force to replace it, or --template-id to use a different ID."
        fi
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    info "========================================================"
    info " 01-create-template.sh"
    info " Template ID  : ${TEMPLATE_ID}"
    info " Template name: ${TEMPLATE_NAME}"
    info " Storage      : ${STORAGE}"
    info " Log file     : ${LOG_FILE}"
    info "========================================================"

    check_prerequisites
    handle_existing
    download_image
    inject_cloud_cfg "${IMAGE_FILE}"
    write_vendor_snippet
    create_vm
    convert_to_template
    verify_template
}

main "$@"
