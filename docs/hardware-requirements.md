# Hardware Requirements

The lab is designed to scale from a single workstation to a multi-host environment. Pick the profile that matches your available hardware.

## Minimum Single-Host Profile

For running 4-6 light VMs on Type-2 hypervisors (VMware Workstation, VirtualBox).

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 4 cores / 8 threads, VT-x / AMD-V enabled | 8 cores / 16 threads |
| RAM | 16 GB | 32 GB+ |
| Storage | 256 GB SSD | 1 TB NVMe |
| Network | 1 GbE | 2.5 GbE or dual 1 GbE |
| OS | Windows 10/11 Pro, Linux, macOS | Windows 11 Pro / Ubuntu 22.04+ |

## Recommended Multi-Host Profile

For a full lab running Hyper-V + Proxmox + a Workstation in parallel.

| Role | Spec |
|------|------|
| Hyper-V host | Windows Server 2022, 8c/16t, 64 GB RAM, 1 TB NVMe + 2 TB SSD |
| Proxmox node | Intel N100 / Ryzen 5 mini-PC, 32 GB RAM, 1 TB NVMe |
| Workstation | i7/Ryzen 7, 32 GB RAM, dual NVMe, dGPU optional |
| NAS | Synology / TrueNAS, 2-4 bay, 8 TB+, NFS + SMB |
| Network | 8-port managed switch (e.g., TP-Link TL-SG108E) |

## CPU Virtualization Extensions

Verify the host CPU exposes virtualization extensions before installing any hypervisor.

**Windows (PowerShell):**

```powershell
Get-ComputerInfo -Property "HyperV*"
systeminfo | Select-String "Virtualization"
```

**Linux:**

```bash
egrep -o '(vmx|svm)' /proc/cpuinfo | head -1
lscpu | grep -i virtualization
```

**Result expectations:**
- `vmx` -> Intel VT-x present
- `svm` -> AMD-V present

If neither flag appears, enable virtualization in the BIOS/UEFI under "Advanced CPU Configuration" or similar.

## Nested Virtualization

Required if you plan to run Hyper-V or Proxmox **inside** VMware Workstation or another hypervisor.

- **VMware Workstation**: enable "Virtualize Intel VT-x/EPT or AMD-V/RVI" in VM CPU settings.
- **Hyper-V**: `Set-VMProcessor -VMName <name> -ExposeVirtualizationExtensions $true`.
- **Proxmox/KVM**: enable nested KVM with `options kvm-intel nested=1` (Intel) or `options kvm-amd nested=1` (AMD).
