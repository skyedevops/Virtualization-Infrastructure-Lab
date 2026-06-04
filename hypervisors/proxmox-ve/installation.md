# Proxmox VE - Installation

## 1. Download

- Get the ISO from <https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso>
- Write to a USB stick with `dd` (Linux/macOS) or Rufus (Windows, **DD mode** only).

```bash
sudo dd if=proxmox-ve_8.2-1.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

## 2. Boot & Install

1. Boot the target host from USB.
2. Choose **Install Proxmox VE (Graphical)**.
3. Accept EULA.
4. **Target Harddisk**:
   - Select `Options` -> **ZFS (RAID1)** if you have two SSDs (recommended).
   - Otherwise `ext4` on a single NVMe.
   - For ZFS, set `ashift=12`, `compress=lz4`, `arc_max=4GB` (smaller hosts).
5. **Country / Timezone / Keyboard**.
6. **Administrator password + Email**.
7. **Management network**:
   - Pick the management NIC.
   - Hostname FQDN: `pve01.lab.local`
   - IP: `10.10.10.11/24`, GW `10.10.10.1`, DNS `10.10.10.1`
8. Confirm and install. ~5 minutes.
9. Reboot, eject USB.

## 3. First Login

- Web UI: `https://10.10.10.11:8006`
- Username: `root`, Realm: `Linux PAM`
- Dismiss the "no subscription" dialog (handled in post-install).

## 4. Post-Install Hardening

Run the bundled script over SSH:

```bash
ssh root@10.10.10.11
curl -fsSL https://raw.githubusercontent.com/<your-fork>/Virtualization-Infrastructure-Lab/main/hypervisors/proxmox-ve/scripts/pve-post-install.sh -o pve-post-install.sh
bash pve-post-install.sh
```

What it does:

- Switches `pve-enterprise.list` to the free `no-subscription` repository
- Adds the `ceph-quincy` no-subscription repo if needed
- `apt update && apt dist-upgrade -y`
- Installs handy tools: `htop`, `iotop`, `tmux`, `qemu-guest-agent`, `lm-sensors`, `unattended-upgrades`, `chrony`
- Disables the "no valid subscription" web nag
- Sets `vm.swappiness=10`, enables `fstrim.timer`
- Locks down SSH: disables root password login, enforces key auth, sets `MaxAuthTries 3`

## 5. Storage Setup

### Add an ISO storage

```bash
pvesm add dir iso --path /var/lib/vz/template/iso --content iso
```

### Add an NFS backup target

```bash
pvesm add nfs nas-backup \
  --server 10.10.99.20 \
  --export /volume1/pve-backup \
  --content backup,vztmpl \
  --options vers=4.1
```

### Create a ZFS pool for VMs (if you didn't choose ZFS at install)

```bash
zpool create -o ashift=12 vmpool mirror /dev/nvme1n1 /dev/nvme2n1
zfs set compression=lz4 vmpool
pvesm add zfspool local-zfs --pool vmpool --content images,rootdir --sparse
```

## 6. Network Bridges

Default `/etc/network/interfaces` after install:

```conf
auto lo
iface lo inet loopback

iface enp1s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.11/24
    gateway 10.10.10.1
    bridge-ports enp1s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes      # add this line to allow VLAN tags per-VM
    bridge-vids 2-4094
```

Add an internal-only bridge for inter-VM traffic that should not leave the host:

```conf
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
```

Apply with `ifreload -a` (after `apt install ifupdown2`).

## 7. Validation

```bash
pveversion -v
pvesh get /nodes/$(hostname -s)/status
ip -br link show type bridge
zpool status
```

You're ready to create VMs. Continue with [vm-configuration.md](vm-configuration.md) or jump to [cluster-setup.md](cluster-setup.md) to add more nodes.
