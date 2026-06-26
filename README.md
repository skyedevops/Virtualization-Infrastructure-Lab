# Virtualization & Infrastructure Lab: A Case Study in Enterprise System Administration

## 📌 Overview
This project is a comprehensive simulation of a corporate datacenter environment. Rather than a simple collection of VMs, this lab is a study in **Infrastructure Lifecycle Management**—covering everything from bare-metal hypervisor installation to high-availability (HA) cluster orchestration and disaster recovery (DR) drills.

The primary goal was to bridge the gap between theoretical virtualization and production-grade systems administration, creating a sandbox where "destructive testing" (like simulated node failures) can be used to validate resilience.

---

## 🚀 The Engineering Challenge
Running a few VMs is simple; managing a virtualized datacenter is complex. The core challenges addressed in this lab were:
1. **Hypervisor Heterogeneity:** Managing the trade-offs between Type-1 (Bare Metal) and Type-2 (Hosted) virtualization for different use cases.
2. **The "Silo" Problem:** Ensuring that networking, storage, and compute are integrated as a single system rather than disconnected components.
3. **The Recovery Gap:** Moving beyond simple snapshots to a professional **3-2-1 Backup Strategy** with verified restore drills.

---

## 🛠️ The Solution: A Multi-Tiered Infrastructure Approach

### 🏗️ Lab Architecture
The lab is designed as a tiered ecosystem, moving from simple testing to complex clustering.

![Home Lab Topology](diagrams/homelab-topology.png)

### 🎯 Key Engineering Implementations

#### 1. Proxmox VE High-Availability Cluster
The centerpiece of the lab is a 3-node Proxmox cluster. I implemented:
*   **Shared Storage:** Configuring a centralized storage backend to allow for **Live Migration**, where VMs move between hosts with zero downtime.
*   **HA Failover:** Testing "Node Death" scenarios to ensure the cluster automatically restarts critical VMs on surviving nodes.
*   **LXC Containerization:** Using Linux Containers for lightweight services, reducing memory overhead by ~40% compared to full VMs.

#### 2. Advanced Network Segmentation
To simulate a corporate environment, I implemented a complex network topology:
*   **pfSense Firewall:** Acting as the edge router and gateway.
*   **VLAN Tagging:** Segmenting the lab into separate zones (e.g., MGMT VLAN, Production VLAN, DMZ) to prevent unauthorized lateral movement.
*   **DHCP/DNS Orchestration:** Centralizing network identity management.

#### 3. Disaster Recovery & Data Integrity
I moved beyond "snapshots" to a professional backup regime:
*   **Proxmox Backup Server (PBS):** Implementing deduplicated, incremental backups.
*   **Restore Drills:** Creating a scheduled script to perform "nightly restore tests," ensuring that backups are actually functional, not just "present."

---

## 📂 Repository Structure

| Path | Engineering Purpose |
| :--- | :--- |
| `hypervisors/` | Detailed implementation guides for Proxmox, VMware, and Hyper-V. |
| `virtual-machines/` | Standardized build-sheets for Linux and Windows guests. |
| `networking/` | Documentation of vSwitches, VLANs, and firewall rules. |
| `snapshots-backup/` | The DR manual: Snapshot policies and PBS restore procedures. |
| `scripts/` | The "Automation Layer"—PowerShell and Bash tools for lab management. |
| `lab.yaml` | The "Infrastructure Manifest"—a declarative list of all lab assets. |

---

## 🚦 Quick Start & Lab Navigation

### 1. Environment Setup
Review the `docs/hardware-requirements.md` to ensure your host can support the desired hypervisor.

### 2. Provisioning the Lab
Use the declarative `lab.yaml` and the `labctl` tool to plan your deployment:
```bash
# Plan the deployment (dry-run)
make plan 

# Execute the provisioning
make apply
```

### 3. Testing Resilience
To test a live migration and HA failover:
```bash
python3 scripts/python/labctl.py migrate --vm <VM_ID> --target <NODE_ID> --execute
```

---

## 📈 Outcomes & Impact
*   **Skill Mastery:** Gained deep expertise in the full virtualization stack, from BIOS/UEFI settings to Cluster Quorum.
*   **Risk Reduction:** Validated a 100% recovery rate for critical VMs through automated restore drills.
*   **Resource Optimization:** Reduced physical hardware requirements by consolidating services into LXC containers.

## 📜 License
MIT
