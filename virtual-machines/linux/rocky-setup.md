# Rocky Linux 9 / RHEL-Family Build

The lab's RPM-based reference build. Steps apply equally to AlmaLinux 9, Oracle Linux 9, and CentOS Stream 9 with no changes.

## Build Specs

| Spec | Value |
|------|-------|
| OS | Rocky Linux 9.x (minimal) |
| Disk | 40 GB (LVM, XFS root) |
| Filesystem | XFS (default) |
| User | `labadmin`, wheel group, SSH key only |
| Boot | UEFI |
| Hardening | firewalld + nftables backend, SELinux enforcing, dnf-automatic |

## 1. Installer (Anaconda)

1. Boot ISO -> **Install Rocky Linux 9**.
2. **Software Selection**: Minimal Install (Standard add-ons checked).
3. **Installation Destination**: Custom -> LVM:
   - 1 GB `/boot/efi` (EFI System Partition, fat32)
   - 1 GB `/boot` (xfs)
   - PV on remainder -> VG `rl` -> LV `root` 20G xfs `/`, `home` 5G xfs `/home`, `var` 10G xfs `/var`, leave 5G free
4. **Network**: enable NIC, set hostname `app01.lab.local`.
5. **Root password**: set + **disable root SSH login** in same dialog.
6. **User Creation**: `labadmin`, **Make this user administrator** (wheel).
7. Begin Installation. Reboot. Remove ISO.

## 2. First Boot

```bash
ssh labadmin@<ip>

sudo dnf -y install epel-release
sudo dnf -y upgrade

sudo dnf -y install \
  vim git tmux htop iotop iftop bind-utils net-tools jq curl wget unzip \
  firewalld nftables chrony \
  dnf-automatic \
  qemu-guest-agent open-vm-tools \
  cockpit cockpit-system

sudo timedatectl set-timezone UTC
sudo systemctl enable --now chronyd firewalld
```text

## 3. SELinux + Firewall

```bash
# SELinux should already be enforcing
getenforce       # Enforcing
sestatus

# firewalld zones
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --set-default-zone=public
sudo firewall-cmd --permanent --add-service=ssh
# add others as needed:
# sudo firewall-cmd --permanent --add-service=http
# sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```text

## 4. Static IP via NetworkManager

```bash
NIC=$(nmcli -t -f DEVICE,STATE device | awk -F: '$2=="connected"{print $1; exit}')
sudo nmcli con mod "$NIC" \
  ipv4.addresses 10.10.20.60/24 \
  ipv4.gateway 10.10.20.1 \
  ipv4.dns "10.10.20.10 1.1.1.1" \
  ipv4.dns-search lab.local \
  ipv4.method manual
sudo nmcli con down "$NIC" && sudo nmcli con up "$NIC"
ip a; ip r; resolvectl status
```text

## 5. SSH Hardening

```bash
sudo install -d -m 700 /home/labadmin/.ssh
echo "ssh-ed25519 AAAA... admin@workstation" | sudo tee -a /home/labadmin/.ssh/authorized_keys
sudo chmod 600 /home/labadmin/.ssh/authorized_keys
sudo chown -R labadmin:labadmin /home/labadmin/.ssh

sudo sed -ri \
  -e 's|^#?PermitRootLogin.*|PermitRootLogin no|' \
  -e 's|^#?PasswordAuthentication.*|PasswordAuthentication no|' \
  /etc/ssh/sshd_config
sudo systemctl reload sshd
```text

## 6. Auto-Updates

```bash
sudo systemctl enable --now dnf-automatic.timer
sudo sed -ri \
  -e 's|^upgrade_type.*|upgrade_type = security|' \
  -e 's|^apply_updates.*|apply_updates = yes|' \
  /etc/dnf/automatic.conf
```text

## 7. Optional Cockpit Web Console

```bash
sudo systemctl enable --now cockpit.socket
sudo firewall-cmd --permanent --add-service=cockpit
sudo firewall-cmd --reload
# Browse to https://<ip>:9090
```text

## 8. Snapshot

Take a baseline snapshot at the hypervisor level (see `snapshots-backup/`).

## 9. Generalize for Cloning

```bash
# Reset machine ID and SSH host keys
sudo truncate -s 0 /etc/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo dnf clean all
sudo rm -rf /var/cache/dnf
history -c
sudo shutdown -h now
```text
