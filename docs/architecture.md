# Lab Architecture

## Design Goals

1. **Multi-hypervisor parity** - exercise the same workload patterns on VMware, Hyper-V, Proxmox, and VirtualBox so the differences in tooling, performance, and management are well understood.
2. **Production-style segmentation** - keep management, server, client, and DMZ traffic on separate VLANs.
3. **Repeatability** - every VM build is documented step-by-step or scripted so the lab can be torn down and rebuilt from scratch.
4. **Disaster recovery first** - snapshots, backups, and restore drills are treated as core deliverables, not afterthoughts.

## Logical Architecture

| Tier | Components | Purpose |
|------|------------|---------|
| Physical | 1 x workstation (Win11 + VMware), 1 x server (Win Srv 2022 + Hyper-V), 1 x mini-PC (Proxmox), portable laptops (VirtualBox) | Compute hosts |
| Network | Managed switch (VLAN-capable), pfSense VM as router/firewall | L2/L3 segmentation + routing |
| Storage | Local NVMe per host, NAS over NFS/SMB for backups | VM storage + backup target |
| Management | Windows AD, DNS, DHCP, Proxmox web UI, vSphere-free management via Workstation | Identity + control plane |

## VLAN Plan

| VLAN | CIDR | Purpose |
|------|------|---------|
| 10 | 10.10.10.0/24 | Management (hypervisors, IPMI) |
| 20 | 10.10.20.0/24 | Servers (AD, DNS, file, app) |
| 30 | 10.10.30.0/24 | Clients (Win10/11, Linux desktops) |
| 40 | 10.10.40.0/24 | DMZ (web, reverse proxy) |
| 99 | 10.10.99.0/24 | Storage / backup |

## Storage Layout

- **Tier 0 (NVMe)** - hypervisor OS + active VM disks
- **Tier 1 (SATA SSD)** - secondary VM disks, ISO library
- **Tier 2 (NAS HDD)** - nightly backups, snapshots, archive

## Backup Strategy (3-2-1)

- **3** copies of data: production, local backup, off-site
- **2** different media: SSD/HDD + cloud (Backblaze B2 or S3)
- **1** off-site copy with monthly restore test
