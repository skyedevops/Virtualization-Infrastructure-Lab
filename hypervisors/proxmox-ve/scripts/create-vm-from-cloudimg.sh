#!/usr/bin/env bash
# create-vm-from-cloudimg.sh
# Build a ready-to-go cloud-init VM from a downloaded Ubuntu cloud image.
# Default: Ubuntu 22.04 LTS, 2 vCPU, 2 GB RAM, 20 GB disk, virtio NIC on vmbr0.

set -euo pipefail

VMID="${VMID:-9000}"
VMNAME="${VMNAME:-ubuntu-cloud-${VMID}}"
MEMORY_MB="${MEMORY_MB:-2048}"
CORES="${CORES:-2}"
DISK_GB="${DISK_GB:-20}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN_TAG="${VLAN_TAG:-}"   # e.g. 20
STORAGE="${STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
IMG_URL="${IMG_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/id_ed25519.pub}"
CIUSER="${CIUSER:-labadmin}"
IPCONFIG="${IPCONFIG:-ip=dhcp}"   # or ip=10.10.20.50/24,gw=10.10.20.1

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi
if qm status "$VMID" &>/dev/null; then
  echo "VM $VMID already exists. Pick a different VMID."; exit 1
fi
if [[ ! -f $SSH_KEY_FILE ]]; then
  echo "SSH key not found at $SSH_KEY_FILE. Generate one with: ssh-keygen -t ed25519"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
IMG_FILE="$WORKDIR/$(basename "$IMG_URL")"

echo "[+] Downloading cloud image..."
curl -fLo "$IMG_FILE" "$IMG_URL"

echo "[+] Resizing base image to ${DISK_GB}G"
qemu-img resize "$IMG_FILE" "${DISK_GB}G"

echo "[+] Creating VM $VMID ($VMNAME)"
NETARG="virtio,bridge=$BRIDGE"
[[ -n $VLAN_TAG ]] && NETARG="$NETARG,tag=$VLAN_TAG"

qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --cpu host \
  --net0 "$NETARG" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0,format=raw" \
  --scsihw virtio-scsi-single \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --serial0 socket --vga serial0

echo "[+] Importing disk..."
qm importdisk "$VMID" "$IMG_FILE" "$STORAGE" --format raw
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-1,discard=on,ssd=1,iothread=1"

echo "[+] Adding cloud-init drive..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --ciuser "$CIUSER"
qm set "$VMID" --sshkeys "$SSH_KEY_FILE"
qm set "$VMID" --ipconfig0 "$IPCONFIG"

# Optional: enable QEMU guest agent
qm set "$VMID" --agent enabled=1

echo "[+] Taking baseline snapshot 'clean'"
qm snapshot "$VMID" clean --description "Fresh cloud-init build $(date -Is)"

echo "[+] Done. Start with: qm start $VMID"
echo "[+] Then SSH:        ssh ${CIUSER}@<ip>"
qm config "$VMID" | grep -E "^(name|cores|memory|net0|scsi0|ipconfig0|ciuser)"
