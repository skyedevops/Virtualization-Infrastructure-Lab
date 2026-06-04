#!/usr/bin/env bash
# linux-vm-postinstall.sh
# One-shot, idempotent post-install hardening + lab baseline for Ubuntu/Debian or RHEL-family.
# Run as the unprivileged admin user with sudo rights.

set -euo pipefail

############### Config (override via env) ###############
TIMEZONE="${TIMEZONE:-UTC}"
HOSTNAME="${HOSTNAME:-$(hostname -s)}"
ADMIN_USER="${ADMIN_USER:-$USER}"
SSH_PUBKEY="${SSH_PUBKEY:-}"                  # optional: full ssh-ed25519 ... string
ALLOW_PORTS="${ALLOW_PORTS:-22/tcp}"          # space-separated
INSTALL_NODE_EXPORTER="${INSTALL_NODE_EXPORTER:-no}"
NODE_EXPORTER_VER="${NODE_EXPORTER_VER:-1.8.0}"
########################################################

step()   { printf "\n\e[36m=== %s ===\e[0m\n" "$*"; }
ok()     { printf "\e[32m[OK]\e[0m %s\n" "$*"; }
fatal()  { printf "\e[31m[FATAL]\e[0m %s\n" "$*"; exit 1; }

if [[ $EUID -eq 0 ]]; then fatal "Run as a normal sudoer user, not root."; fi
command -v sudo >/dev/null || fatal "sudo not installed."

# Detect distro family
. /etc/os-release
case "${ID_LIKE:-$ID}" in
  *debian*|debian|ubuntu) FAMILY=debian ;;
  *rhel*|*fedora*|rhel|fedora|rocky|almalinux|centos) FAMILY=rhel ;;
  *) fatal "Unsupported distro: $ID" ;;
esac
ok "Detected family: $FAMILY ($PRETTY_NAME)"

# ------------------------------------------------------------------
step "Hostname + timezone"
sudo hostnamectl set-hostname "$HOSTNAME"
sudo timedatectl set-timezone "$TIMEZONE"

# ------------------------------------------------------------------
step "Package update + base tools"
if [[ $FAMILY == debian ]]; then
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -qq
  sudo apt-get -y dist-upgrade
  sudo apt-get -y install \
    vim git tmux htop iotop iftop bind9-utils net-tools jq curl wget unzip \
    ufw fail2ban unattended-upgrades chrony \
    qemu-guest-agent open-vm-tools \
    ca-certificates
  sudo systemctl enable --now chrony fail2ban unattended-upgrades
else
  sudo dnf -y install epel-release || true
  sudo dnf -y upgrade
  sudo dnf -y install \
    vim git tmux htop iotop iftop bind-utils net-tools jq curl wget unzip \
    firewalld chrony dnf-automatic \
    qemu-guest-agent open-vm-tools
  sudo systemctl enable --now chronyd firewalld dnf-automatic.timer
fi
ok "Packages installed"

# ------------------------------------------------------------------
step "SSH hardening"
SSHD=/etc/ssh/sshd_config
sudo cp $SSHD ${SSHD}.bak.$(date +%s)

# Add SSH key if provided
if [[ -n $SSH_PUBKEY ]]; then
  sudo install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  echo "$SSH_PUBKEY" | sudo tee -a "/home/$ADMIN_USER/.ssh/authorized_keys" >/dev/null
  sudo chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  sudo chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
  KEY_ENFORCEMENT=1
  ok "Authorized key installed for $ADMIN_USER"
else
  KEY_ENFORCEMENT=0
  echo "[!] No SSH_PUBKEY provided; leaving password auth enabled."
fi

sudo sed -ri \
  -e 's|^#?PermitRootLogin.*|PermitRootLogin no|' \
  -e 's|^#?MaxAuthTries.*|MaxAuthTries 3|' \
  -e 's|^#?ClientAliveInterval.*|ClientAliveInterval 300|' \
  -e 's|^#?ClientAliveCountMax.*|ClientAliveCountMax 2|' \
  $SSHD
if [[ $KEY_ENFORCEMENT -eq 1 ]]; then
  sudo sed -ri \
    -e 's|^#?PasswordAuthentication.*|PasswordAuthentication no|' \
    -e 's|^#?KbdInteractiveAuthentication.*|KbdInteractiveAuthentication no|' \
    $SSHD
fi
sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd

# ------------------------------------------------------------------
step "Firewall"
if [[ $FAMILY == debian ]]; then
  sudo ufw --force reset >/dev/null
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  for p in $ALLOW_PORTS; do sudo ufw allow "$p"; done
  sudo ufw --force enable
  sudo ufw status verbose
else
  for p in $ALLOW_PORTS; do
    proto="${p##*/}"; port="${p%%/*}"
    sudo firewall-cmd --permanent --add-port="${port}/${proto}"
  done
  sudo firewall-cmd --reload
  sudo firewall-cmd --list-all
fi

# ------------------------------------------------------------------
if [[ $INSTALL_NODE_EXPORTER == yes ]]; then
  step "Installing Prometheus node_exporter $NODE_EXPORTER_VER"
  cd /tmp
  curl -fsSLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-amd64.tar.gz"
  tar xzf "node_exporter-${NODE_EXPORTER_VER}.linux-amd64.tar.gz"
  sudo install -m 755 "node_exporter-${NODE_EXPORTER_VER}.linux-amd64/node_exporter" /usr/local/bin/
  sudo useradd -rs /usr/sbin/nologin node_exporter 2>/dev/null || true
  sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now node_exporter
  if [[ $FAMILY == debian ]]; then
    sudo ufw allow 9100/tcp
  else
    sudo firewall-cmd --permanent --add-port=9100/tcp && sudo firewall-cmd --reload
  fi
  ok "node_exporter listening on :9100"
fi

# ------------------------------------------------------------------
step "Summary"
hostnamectl status | head -5
timedatectl status | head -3
ip -br a | grep -v 'lo\b'
echo "[OK] Post-install complete. Reboot recommended."
