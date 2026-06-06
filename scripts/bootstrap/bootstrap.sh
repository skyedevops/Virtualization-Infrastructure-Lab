#!/usr/bin/env bash
# bootstrap.sh - Turn a fresh Proxmox VE install into a working lab node.
#
# This script is meant to be run ON the Proxmox host itself, as root, after
# the standard Proxmox ISO installer has finished. It is idempotent.
#
# What it does:
#   1. Post-install hardening (repos, updates, sysctl, SSH key-only)
#   2. Configures the default Linux bridge for VLAN-aware operation
#   3. Adds an NFS / directory storage for VM templates and ISOs
#   4. Uploads / fetches the default ISO library
#   5. Clones the lab repo (or updates it) into /opt/lab
#   6. Optionally runs labctl.py apply against the local node
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<fork>/Virtualization-Infrastructure-Lab/main/scripts/bootstrap/bootstrap.sh | bash -s -- [options]
#   # or, locally:
#   ./scripts/bootstrap/bootstrap.sh
#   ./scripts/bootstrap/bootstrap.sh --repo https://github.com/<fork>/<repo>.git --apply
#
# Environment / config:
#   LAB_REPO   - git URL of the lab repo (default: GitHub origin)
#   LAB_BRANCH - branch to track (default: main)
#   LAB_PATH   - where to clone the repo (default: /opt/lab)
#   LAB_LAB    - path to lab.yaml relative to the repo (default: lab.yaml)

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ----------------------------------------------------------------------------- 
# Parse args
# -----------------------------------------------------------------------------
REPO="${LAB_REPO:-https://github.com/skyedevops/Virtualization-Infrastructure-Lab.git}"
BRANCH="${LAB_BRANCH:-main}"
LAB_PATH="${LAB_PATH:-/opt/lab}"
APPLY=0
SKIP_HARDEN=0
SKIP_NET=0
SKIP_STORAGE=0
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --path)   LAB_PATH="$2"; shift 2 ;;
    --apply)  APPLY=1; shift ;;
    --skip-harden)   SKIP_HARDEN=1; shift ;;
    --skip-network)  SKIP_NET=1; shift ;;
    --skip-storage)  SKIP_STORAGE=1; shift ;;
    --ssh-key) SSH_PUBKEY_FILE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()   { printf "\e[36m[+]\e[0m %s\n" "$*"; }
ok()    { printf "\e[32m[OK]\e[0m %s\n" "$*"; }
warn()  { printf "\e[33m[!]\e[0m %s\n" "$*"; }
fail()  { printf "\e[31m[FATAL]\e[0m %s\n" "$*"; exit 1; }

if [[ $EUID -ne 0 ]]; then fail "Run as root."; fi
if ! command -v pveversion >/dev/null; then fail "pveversion not found - is this a Proxmox host?"; fi

PVE_MAJOR="$(pveversion | awk -F/ '{print $2}' | cut -d. -f1)"
log "Detected Proxmox VE major version: $PVE_MAJOR"

# -----------------------------------------------------------------------------
# 1. Post-install hardening (delegated to the existing pve-post-install.sh)
# -----------------------------------------------------------------------------
if [[ $SKIP_HARDEN -eq 0 ]]; then
  log "Running post-install hardening"
  # We are inside the lab repo (or about to clone it) so we can call the
  # script from the repo. If not yet cloned, clone first to get the script.
  if [[ ! -d $LAB_PATH ]]; then
    log "Cloning lab repo to $LAB_PATH"
    apt-get install -y git
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$LAB_PATH"
  fi
  if [[ -x $LAB_PATH/hypervisors/proxmox-ve/scripts/pve-post-install.sh ]]; then
    bash "$LAB_PATH/hypervisors/proxmox-ve/scripts/pve-post-install.sh"
    ok "Hardening applied"
  else
    warn "pve-post-install.sh not found in $LAB_PATH - skipping hardening"
  fi
else
  warn "Skipping hardening (--skip-harden)"
  if [[ ! -d $LAB_PATH ]]; then
    log "Cloning lab repo to $LAB_PATH"
    apt-get install -y git
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$LAB_PATH"
  fi
fi

# -----------------------------------------------------------------------------
# 2. SSH public key installation (so labctl can reach this host)
# -----------------------------------------------------------------------------
if [[ -n $SSH_PUBKEY_FILE && -f $SSH_PUBKEY_FILE ]]; then
  log "Installing SSH public key from $SSH_PUBKEY_FILE"
  install -d -m 700 /root/.ssh
  cat "$SSH_PUBKEY_FILE" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  ok "Public key installed"
fi

# -----------------------------------------------------------------------------
# 3. Network - VLAN-aware bridge (idempotent)
# -----------------------------------------------------------------------------
if [[ $SKIP_NET -eq 0 ]]; then
  log "Ensuring vmbr0 is VLAN-aware"
  IFCFG=/etc/network/interfaces
  if ! grep -q "bridge-vlan-aware yes" "$IFCFG" 2>/dev/null; then
    cp "$IFCFG" "${IFCFG}.bak.$(date +%s)"
    if grep -q "^auto vmbr0" "$IFCFG"; then
      sed -i '/^auto vmbr0/,/^$/ {
        /bridge-vlan-aware/d
      }' "$IFCFG"
    fi
    # Insert bridge-vlan-aware and bridge-vids just before the iface line
    sed -i '/iface vmbr0 inet static/a\    bridge-vlan-aware yes\n    bridge-vids 2-4094' "$IFCFG"
    ok "vmbr0 patched (review with: cat $IFCFG)"
  else
    ok "vmbr0 already VLAN-aware"
  fi
else
  warn "Skipping network changes (--skip-network)"
fi

# -----------------------------------------------------------------------------
# 4. Storage - ISO and template dir already exist post-install; just verify
# -----------------------------------------------------------------------------
if [[ $SKIP_STORAGE -eq 0 ]]; then
  log "Verifying default storages"
  pvesm status
  if ! pvesm status -storage local 2>/dev/null | grep -q "local"; then
    fail "Default 'local' storage missing"
  fi
  if ! pvesm status -storage local-lvm 2>/dev/null | grep -q "local-lvm"; then
    warn "Default 'local-lvm' missing - ZFS install? Continuing."
  fi
  ok "Storages OK"
else
  warn "Skipping storage check (--skip-storage)"
fi

# -----------------------------------------------------------------------------
# 5. ISO library - print expected vs present
# -----------------------------------------------------------------------------
ISO_DIR=/var/lib/vz/template/iso
log "Expected ISOs (compare against $ISO_DIR):"
cat <<'EOF'
  - pfSense-CE-2.7.2-RELEASE-amd64.iso
  - proxmox-backup-server-3.2.iso
  - ubuntu-22.04.4-live-server-amd64.iso
  - WindowsServer2022.iso          (place in a Win-friendly share)
  - Win10_22H2_English_x64v1.iso
EOF
log "Currently present:"
ls -1 "$ISO_DIR" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 6. labctl dependency (PyYAML)
# -----------------------------------------------------------------------------
log "Ensuring Python + PyYAML for labctl"
if ! command -v python3 >/dev/null; then
  apt-get install -y python3 python3-pip
fi
python3 -c 'import yaml' 2>/dev/null || pip install --break-system-packages pyyaml 2>/dev/null \
  || pip install pyyaml
ok "labctl dependencies ready"

# -----------------------------------------------------------------------------
# 7. Optional: run labctl apply against this node
# -----------------------------------------------------------------------------
if [[ $APPLY -eq 1 ]]; then
  log "Running labctl apply against local node"
  pushd "$LAB_PATH" >/dev/null
  # Find the local hypervisor entry - the one whose host is this machine
  THIS_HOST_IP=$(ip -4 -j route get 1.1.1.1 2>/dev/null | jq -r '.[0].prefsrc' 2>/dev/null || hostname -I | awk '{print $1}')
  if [[ -n $THIS_HOST_IP ]]; then
    log "Local IP: $THIS_HOST_IP"
    # Apply only VMs whose hypervisor targets this IP, and only the local
    # hypervisor (to avoid touching remote hosts accidentally)
    if grep -q "^      host: $THIS_HOST_IP" lab.yaml; then
      LOCAL_HV=$(awk '/^hypervisors:/{flag=1; next} flag && /^  [a-z]/{name=$1; sub(":","",name)} flag && /host:/{print name; flag=0}' lab.yaml | head -1 | tr -d ' ')
      log "Detected local hypervisor entry: $LOCAL_HV"
      python3 scripts/python/labctl.py apply --hypervisor "$LOCAL_HV"
    else
      warn "No hypervisor in lab.yaml points at $THIS_HOST_IP. Skipping apply."
      log "Add your host to lab.yaml and re-run: $0 --apply"
    fi
  else
    warn "Could not detect local IP. Skipping apply."
  fi
  popd >/dev/null
else
  log "Skipping labctl apply. To provision VMs, re-run with --apply"
fi

echo ""
echo "========== Bootstrap complete =========="
echo "Lab repo: $LAB_PATH"
echo "Next steps:"
echo "  cd $LAB_PATH"
echo "  python3 scripts/python/labctl.py validate"
echo "  python3 scripts/python/labctl.py inventory"
echo "  python3 scripts/python/labctl.py plan"
echo "  python3 scripts/python/labctl.py apply --execute --yes"
