# Ubuntu Server 22.04 LTS - Standard Build

This is the lab's reference Linux build. The same procedure (with minor `apt`/`dnf` swaps) applies to Debian 12, Rocky 9, and Alma 9.

## Build Specs

| Spec | Value |
|------|-------|
| OS | Ubuntu Server 22.04.4 LTS |
| Disk | 40 GB (LVM, single PV, root LV expandable) |
| Filesystem | ext4 (default) or ZFS root if hypervisor supports |
| User | `labadmin`, sudoers, SSH key only |
| Hostname | matches VM name |
| Timezone | UTC |
| Locale | en_US.UTF-8 |
| Boot | UEFI |
| Hardening | UFW enabled, fail2ban, unattended-upgrades, no root SSH |

## 1. Installer Walk-Through

1. Boot ISO -> **Try or Install Ubuntu Server**.
2. Language -> English.
3. Keyboard -> auto-detect.
4. Installer type -> **Ubuntu Server (minimized)** for a smaller footprint.
5. Network -> DHCP for now (set static later via netplan).
6. Proxy -> blank.
7. Mirror -> default or local mirror.
8. Storage -> **Custom storage layout** (recommended):
   - 1 GB EFI partition (`/boot/efi`, fat32)
   - 1 GB ext4 `/boot`
   - Remainder as PV in VG `vg0`
     - LV `root` 20 GB ext4 `/`
     - LV `home` 5 GB ext4 `/home`
     - LV `var` 10 GB ext4 `/var`
     - Leave ~5 GB free in `vg0` for snapshots / growth
9. Profile:
   - Name: `Lab Admin`
   - Server name: `<hostname>` (matches VM name)
   - Username: `labadmin`
   - Strong password
10. **Install OpenSSH server** -> Yes
11. Import SSH key from GitHub if you have one.
12. **Featured Server Snaps** -> none.
13. Wait for install -> reboot -> remove ISO.

## 2. First Boot Tasks

Run the bundled provisioning script (or paste these blocks manually):

```bash
ssh labadmin@<ip>

# update + base tools
sudo apt update && sudo apt -y dist-upgrade
sudo apt install -y \
  htop iotop iftop net-tools dnsutils \
  curl wget jq git tmux unzip vim \
  ufw fail2ban unattended-upgrades \
  qemu-guest-agent open-vm-tools \
  chrony

# hostname (if not set during install)
sudo hostnamectl set-hostname web01.lab.local
sudo timedatectl set-timezone UTC
```text

## 3. Static IP via netplan

Edit `/etc/netplan/00-installer-config.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: no
      addresses: [10.10.20.50/24]
      routes:
        - to: default
          via: 10.10.20.1
      nameservers:
        addresses: [10.10.20.10, 1.1.1.1]
        search: [lab.local]
```text

```bash
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan generate
sudo netplan apply
ip a; ip r; resolvectl status
```text

## 4. SSH Hardening

```bash
sudo install -d -m 700 ~/.ssh
# Append your public key:
echo "ssh-ed25519 AAAA... admin@workstation" | sudo tee -a /home/labadmin/.ssh/authorized_keys
sudo chmod 600 /home/labadmin/.ssh/authorized_keys
sudo chown -R labadmin:labadmin /home/labadmin/.ssh

sudo sed -ri \
  -e 's|^#?PermitRootLogin.*|PermitRootLogin no|' \
  -e 's|^#?PasswordAuthentication.*|PasswordAuthentication no|' \
  -e 's|^#?KbdInteractiveAuthentication.*|KbdInteractiveAuthentication no|' \
  -e 's|^#?MaxAuthTries.*|MaxAuthTries 3|' \
  /etc/ssh/sshd_config
sudo systemctl reload ssh
```text

## 5. Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
# add app rules as needed:
# sudo ufw allow 80/tcp
# sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose
```text

## 6. fail2ban + auto-updates

```bash
sudo systemctl enable --now fail2ban
sudo systemctl enable --now unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # confirm "Yes"
```text

## 7. Hypervisor Guest Agent

| Hypervisor | Package |
|------------|---------|
| Hyper-V    | `hyperv-daemons linux-tools-virtual linux-cloud-tools-virtual` |
| Proxmox / KVM | `qemu-guest-agent` |
| VMware     | `open-vm-tools` |
| VirtualBox | Guest Additions ISO (see VirtualBox docs) |

Already installed in step 2 (we install all of them for portability).

## 8. Monitoring Agent (optional)

```bash
# node_exporter for Prometheus
cd /tmp
VER="1.8.0"
curl -fLO https://github.com/prometheus/node_exporter/releases/download/v${VER}/node_exporter-${VER}.linux-amd64.tar.gz
tar xzf node_exporter-${VER}.linux-amd64.tar.gz
sudo install -m 755 node_exporter-${VER}.linux-amd64/node_exporter /usr/local/bin/

sudo useradd -rs /usr/sbin/nologin node_exporter
sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
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
sudo ufw allow from 10.10.20.0/24 to any port 9100 proto tcp
```text

## 9. Baseline Snapshot

After all of the above, take a hypervisor-level snapshot named `clean-baseline`:

- **Proxmox**: `qm snapshot <vmid> clean-baseline`
- **Hyper-V**: `Checkpoint-VM -Name <name> -SnapshotName clean-baseline`
- **VMware**: `vmrun snapshot "<vmx>" clean-baseline`
- **VirtualBox**: `VBoxManage snapshot "<name>" take clean-baseline`

## 10. Conversion to Golden Template

```bash
# Reset cloud-init / machine identity so clones get unique IDs
sudo cloud-init clean --logs --machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*
history -c
sudo shutdown -h now
```text

Take a snapshot named `golden` on the powered-off VM. Future VMs are linked clones of this snapshot.
