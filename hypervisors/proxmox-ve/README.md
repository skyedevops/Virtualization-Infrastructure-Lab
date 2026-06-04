# Proxmox VE

Proxmox Virtual Environment is an open-source, Debian-based, Type-1 hypervisor combining KVM (full virtualization) and LXC (containers) with a unified web UI, REST API, and built-in clustering, HA, and backup. In this lab, Proxmox runs on a dedicated mini-PC and acts as the "datacenter" tier.

## Version Tested

| Component | Version |
|-----------|---------|
| Proxmox VE | 8.2.x (Debian 12 Bookworm base) |
| Kernel | 6.8.x |
| Proxmox Backup Server | 3.2.x |
| qemu / KVM | 8.1.x |
| LXC | 5.0.x |

## Contents

- [installation.md](installation.md) - Bare-metal install + initial config
- [cluster-setup.md](cluster-setup.md) - Multi-node clustering and HA
- [scripts/](scripts/) - Bash + API automation library

## Why Proxmox in This Lab

| Capability | Proxmox VE |
|------------|------------|
| Web UI included | yes (port 8006) |
| KVM + LXC | yes (mixed on same node) |
| ZFS root | yes (recommended) |
| Built-in clustering | yes (Corosync) |
| Built-in HA | yes (with shared storage) |
| Built-in backup | yes (vzdump + Proxmox Backup Server) |
| Live migration | yes |
| REST API | yes (full feature parity with UI) |
| License cost | free; optional paid subscription for enterprise repo |

## Quick CLI Reference

```bash
# Node
pveversion -v
pvesh get /nodes/$(hostname -s)/status

# VM lifecycle (KVM)
qm list
qm create 101 --name web01 --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 101 ubuntu-22.04-server.img local-lvm
qm set 101 --scsi0 local-lvm:vm-101-disk-0
qm set 101 --boot order=scsi0
qm start 101
qm stop 101
qm shutdown 101
qm destroy 101 --purge

# Snapshots
qm snapshot 101 pre-upgrade --description "Before kernel bump"
qm listsnapshot 101
qm rollback 101 pre-upgrade
qm delsnapshot 101 pre-upgrade

# LXC containers
pct list
pct create 200 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname runner01 --memory 512 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs local-lvm:8
pct start 200
pct enter 200

# Storage
pvesm status
pvesm list local-lvm

# Cluster
pvecm status
pvecm nodes

# Backup
vzdump 101 --storage local --mode snapshot --compress zstd
```

## Featured Scripts (this repo)

| Script | Purpose |
|--------|---------|
| `scripts/pve-post-install.sh` | Disable enterprise repo, enable no-subscription, basic hardening |
| `scripts/create-vm-from-cloudimg.sh` | Build a cloud-init VM from a downloaded Ubuntu cloud image |
| `scripts/snapshot-rotate.sh` | Daily/weekly snapshot rotation with retention |
| `scripts/backup-all-vms.sh` | Run `vzdump` on every VM/CT with retention policy |
| `scripts/pve-api-example.py` | Python example using the REST API |
