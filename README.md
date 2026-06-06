# Virtualization & Infrastructure Lab

A comprehensive home lab project demonstrating the design, deployment, and administration of virtualized environments across multiple hypervisor platforms. This lab serves as a hands-on portfolio for infrastructure engineering, systems administration, and DevOps practices.

---

## Project Overview

This lab was built to gain practical, production-grade experience with the major Type-1 and Type-2 hypervisors used across enterprise and SMB environments. It covers the full lifecycle of a virtual machine: provisioning, networking, hardening, snapshotting, backup, and disaster recovery.

### Key Skills Demonstrated

- Design and deployment of multi-hypervisor virtualization platforms
- Configuration of Linux (Ubuntu, CentOS/Rocky, Debian) and Windows (Server 2019/2022, Windows 10/11) guests
- Virtual networking: bridged, NAT, host-only, internal switches, and VLAN tagging
- Snapshot management, scheduled backups, and bare-metal recovery procedures
- Resource allocation, performance tuning, and capacity planning
- Automation with PowerShell, Bash, and the Proxmox API

---

## Hypervisors Deployed

| Hypervisor | Type | Host OS | Primary Use Case |
|------------|------|---------|------------------|
| **VMware Workstation Pro 17** | Type-2 | Windows 11 | Desktop lab, nested labs, OS testing |
| **Microsoft Hyper-V** | Type-1 | Windows Server 2022 | Windows-centric production-style lab |
| **Proxmox VE 8.x** | Type-1 | Debian 12 (bare metal) | Open-source datacenter, clustering, KVM/LXC |
| **Oracle VirtualBox 7** | Type-2 | Linux & Windows | Cross-platform dev/test, Vagrant integration |

---

## Lab Topology

```text
                       Internet / WAN
                            |
                     +------+------+
                     |  pfSense FW |
                     |  (VM Router)|
                     +------+------+
                            |
            +---------------+----------------+
            |        MGMT VLAN 10            |
            +----+--------+--------+---------+
                 |        |        |
        +--------+--+ +---+----+ +-+--------+
        | Proxmox  | | Hyper-V| | VMware   |
        | Node 01  | | Host   | | Workstn. |
        +-----+----+ +---+----+ +----+-----+
              |          |           |
        +-----+----+ +---+----+ +----+-----+
        | Linux VMs| | WinSrv | | Mixed    |
        | LXC      | | AD/DNS | | Guests   |
        +----------+ +--------+ +----------+
```text

See [docs/lab-topology.md](docs/lab-topology.md) for the full network and storage topology.

---

## Repository Structure

```text
.
├── docs/                        # Architecture, hardware, topology
├── hypervisors/
│   ├── vmware-workstation/      # VMware Workstation guides
│   ├── hyper-v/                 # Hyper-V guides + PowerShell
│   ├── proxmox-ve/              # Proxmox guides + Bash/API
│   └── virtualbox/              # VirtualBox guides + VBoxManage
├── virtual-machines/
│   ├── linux/                   # Linux guest build guides + scripts
│   └── windows/                 # Windows guest build guides + scripts
├── networking/                  # vSwitches, VLANs, firewall rules
├── snapshots-backup/            # Snapshot, backup, and DR procedures
├── resource-management/         # CPU, memory, storage allocation
├── scripts/
│   ├── powershell/              # Hyper-V / Windows automation
│   ├── bash/                    # Proxmox / Linux automation
│   └── python/                  # Cross-platform tooling
└── diagrams/                    # Network and architecture diagrams
```text

---

## Quick Start

1. Review [docs/hardware-requirements.md](docs/hardware-requirements.md) to validate your host hardware.
2. Pick a hypervisor under `hypervisors/` and follow its installation guide.
3. Use the guest build guides under `virtual-machines/` to provision your first VM.
4. Implement networking from `networking/README.md`.
5. Establish your snapshot and backup baseline from `snapshots-backup/README.md`.

---

## Outcomes

By completing this lab end-to-end you will have:

- A working multi-hypervisor environment with at least 8-10 active VMs
- A documented, repeatable VM build process for Linux and Windows
- A tested 3-2-1 backup strategy with verified restore procedures
- Automation scripts for routine provisioning and maintenance tasks
- A network design with segmentation, DHCP, DNS, and firewalling

---

## License

MIT - see [LICENSE](LICENSE).
