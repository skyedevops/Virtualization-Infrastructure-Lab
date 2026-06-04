# Lab Topology

## Physical Topology

```
                    ┌──────────────────┐
                    │   ISP / WAN      │
                    └────────┬─────────┘
                             │
                    ┌────────┴─────────┐
                    │  Home Router     │  192.168.1.1/24
                    │  (ISP-provided)  │
                    └────────┬─────────┘
                             │
                    ┌────────┴─────────┐
                    │  pfSense VM      │  WAN: DHCP
                    │  (on Proxmox)    │  LAN: 10.10.0.1
                    └────────┬─────────┘
                             │
                    ┌────────┴─────────┐
                    │  Managed Switch  │  802.1Q trunk
                    │  TL-SG108E       │
                    └─┬──┬──┬──┬──┬────┘
                      │  │  │  │  │
            ┌─────────┘  │  │  │  └─────────┐
            │            │  │  │            │
       ┌────┴────┐  ┌────┴┐ │ ┌┴───────┐ ┌─┴─────┐
       │ Hyper-V │  │ PVE │ │ │ Wkstn  │ │  NAS  │
       │  Host   │  │ Node│ │ │ Laptop │ │       │
       └─────────┘  └─────┘ │ └────────┘ └───────┘
                            │
                       ┌────┴────┐
                       │  Admin  │
                       │ Laptop  │
                       └─────────┘
```

## VLAN Topology

| VLAN ID | Name | Subnet | Gateway | DHCP Range |
|---------|------|--------|---------|------------|
| 10 | MGMT | 10.10.10.0/24 | 10.10.10.1 | static only |
| 20 | SERVERS | 10.10.20.0/24 | 10.10.20.1 | 10.10.20.100-200 |
| 30 | CLIENTS | 10.10.30.0/24 | 10.10.30.1 | 10.10.30.100-250 |
| 40 | DMZ | 10.10.40.0/24 | 10.10.40.1 | static only |
| 99 | STORAGE | 10.10.99.0/24 | 10.10.99.1 | static only |

## Per-Hypervisor Virtual Switch Layout

### VMware Workstation
- **VMnet0** - Bridged to physical NIC (uplink to switch trunk)
- **VMnet1** - Host-only (10.10.30.0/24 client lab)
- **VMnet8** - NAT (default, for internet-only guests)

### Hyper-V
- **vSwitch-External** - External, bound to physical NIC, allows management OS
- **vSwitch-Internal** - Internal, 10.10.20.0/24 servers VLAN
- **vSwitch-Private** - Private, isolated test bench

### Proxmox VE
- **vmbr0** - Linux bridge on enp1s0, VLAN-aware
- **vmbr1** - Linux bridge, internal-only (no physical NIC)
- VLAN tags applied per-VM via `tag=` in NIC config

### VirtualBox
- **NAT Network "LabNet"** - 10.10.50.0/24, DHCP enabled
- **Host-Only "vboxnet0"** - 192.168.56.0/24
- **Bridged** - per VM, to physical NIC when needed

## Service Placement

| Service | Host | VM Name | IP | OS |
|---------|------|---------|-----|----|
| Firewall/Router | Proxmox | pfsense-01 | 10.10.10.1 | FreeBSD |
| Domain Controller | Hyper-V | dc01 | 10.10.20.10 | Win Srv 2022 |
| DNS / DHCP | Hyper-V | dc01 | 10.10.20.10 | Win Srv 2022 |
| File Server | Hyper-V | fs01 | 10.10.20.20 | Win Srv 2022 |
| Web Server | Proxmox | web01 | 10.10.40.10 | Ubuntu 22.04 |
| Reverse Proxy | Proxmox | nginx-rp | 10.10.40.5 | Debian 12 |
| Monitoring | Proxmox | grafana | 10.10.20.50 | Ubuntu 22.04 |
| Backup Server | Proxmox | pbs01 | 10.10.99.10 | Proxmox Backup Server |
