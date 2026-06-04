#!/usr/bin/env bash
# pve-post-install.sh
# Post-install hardening and convenience setup for a fresh Proxmox VE 8.x node.
# Safe to re-run.

set -euo pipefail

log() { printf "\e[36m[+]\e[0m %s\n" "$*"; }
ok()  { printf "\e[32m[OK]\e[0m %s\n" "$*"; }
warn(){ printf "\e[33m[!]\e[0m %s\n" "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

PVE_VERSION="$(pveversion | awk -F/ '{print $2}' | cut -d. -f1)"
log "Detected Proxmox VE major version: ${PVE_VERSION}"

###############################################################################
# 1. Repositories: disable enterprise, enable no-subscription
###############################################################################
log "Configuring APT repositories (no-subscription)"

if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
  sed -ri 's|^deb |# deb |' /etc/apt/sources.list.d/pve-enterprise.list
fi
if [[ -f /etc/apt/sources.list.d/ceph.list ]]; then
  sed -ri 's|^deb |# deb |' /etc/apt/sources.list.d/ceph.list
fi

cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $(lsb_release -cs) pve-no-subscription
EOF

cat > /etc/apt/sources.list.d/ceph-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/ceph-quincy $(lsb_release -cs) no-subscription
EOF

ok "Repositories updated"

###############################################################################
# 2. System update + useful packages
###############################################################################
log "Updating system packages (this may take a few minutes)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y dist-upgrade
apt-get -y install \
  htop iotop iftop tmux vim curl wget jq git \
  qemu-guest-agent lm-sensors smartmontools nvme-cli \
  unattended-upgrades chrony \
  bridge-utils ifupdown2 ethtool
ok "Packages installed"

###############################################################################
# 3. Remove the "no valid subscription" web nag
###############################################################################
NAGFILE=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [[ -f $NAGFILE ]]; then
  log "Removing subscription nag (web UI)"
  sed -i.bak "s|res === null || res === undefined || \\!res || res\n\t\t\t.data.status.toLowerCase() !== 'active'|false|g" $NAGFILE || true
  systemctl restart pveproxy.service
  ok "Nag removed"
fi

###############################################################################
# 4. Time sync
###############################################################################
log "Enabling chrony"
systemctl enable --now chrony

###############################################################################
# 5. Kernel + I/O tuning
###############################################################################
log "Applying sysctl tuning"
cat > /etc/sysctl.d/99-pve-lab.conf <<EOF
# Reduce swap pressure
vm.swappiness = 10

# Network buffers for higher-throughput VMs
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# More inotify watches (useful for nested dev VMs)
fs.inotify.max_user_watches = 524288
EOF
sysctl --system >/dev/null
ok "sysctl applied"

# Enable weekly fstrim for SSDs
systemctl enable --now fstrim.timer

###############################################################################
# 6. SSH hardening
###############################################################################
log "Hardening SSH"
SSHD=/etc/ssh/sshd_config
sed -ri 's|^#?PermitRootLogin.*|PermitRootLogin prohibit-password|' $SSHD
sed -ri 's|^#?PasswordAuthentication.*|PasswordAuthentication no|' $SSHD
sed -ri 's|^#?MaxAuthTries.*|MaxAuthTries 3|' $SSHD
sed -ri 's|^#?ClientAliveInterval.*|ClientAliveInterval 300|' $SSHD
sed -ri 's|^#?ClientAliveCountMax.*|ClientAliveCountMax 2|' $SSHD

if [[ ! -f /root/.ssh/authorized_keys || ! -s /root/.ssh/authorized_keys ]]; then
  warn "No SSH public key found for root. Disabling password login will lock you out."
  warn "Either add a key to /root/.ssh/authorized_keys before the next SSH session,"
  warn "or revert PasswordAuthentication=yes in $SSHD."
else
  systemctl reload ssh
  ok "SSH hardened (key-only)"
fi

###############################################################################
# 7. Unattended security updates
###############################################################################
log "Enabling unattended-upgrades"
cat > /etc/apt/apt.conf.d/52unattended-upgrades-pve <<EOF
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable --now unattended-upgrades

###############################################################################
# 8. Summary
###############################################################################
echo ""
echo "========== Post-install complete =========="
pveversion
echo ""
echo "Next steps:"
echo "  - Add storage:    pvesm add nfs nas-backup ..."
echo "  - Create a VM:    bash create-vm-from-cloudimg.sh"
echo "  - Build a cluster:  pvecm create lab-cluster"
