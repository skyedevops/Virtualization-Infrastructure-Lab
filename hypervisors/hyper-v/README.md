# Microsoft Hyper-V

Hyper-V is the Type-1 hypervisor built into Windows Server and Windows Pro/Enterprise. This lab uses Hyper-V on **Windows Server 2022** as the Windows-centric production-style environment, with all VM operations driven through PowerShell.

## Version Tested

| Component | Version |
|-----------|---------|
| Hyper-V Role | Windows Server 2022 (build 20348) |
| Hyper-V Manager | 10.0.x |
| PowerShell module | `Hyper-V` v2.0.0.0 |
| Integration Services | Latest (auto-installed for supported guests) |

## Contents

- [installation.md](installation.md) - Enable role, configure host
- [vm-configuration.md](vm-configuration.md) - Build VMs with PowerShell
- [scripts/](scripts/) - PowerShell automation library

## When to Use Hyper-V vs. Other Hypervisors

| Use Case | Recommendation |
|----------|----------------|
| Windows-only workloads, AD-integrated mgmt | Hyper-V |
| Mixed Linux/Windows with web GUI for cluster | Proxmox |
| Desktop / portable lab, OS testing | VMware Workstation / VirtualBox |
| Production-grade enterprise + vendor support | VMware ESXi/vSphere (out of scope) |

## Hyper-V Architecture Recap

- **Parent partition** - the management OS (Windows Server) that hosts the Hyper-V stack
- **Child partitions** - the guest VMs
- **VMBus** - high-speed inter-partition communication channel
- **Integration Services (IS)** - the in-guest drivers that enable enlightened I/O, heartbeat, time sync, etc.

## Quick PowerShell Reference

```powershell
# Module
Import-Module Hyper-V
Get-Command -Module Hyper-V | Measure-Object   # ~245 cmdlets

# Inventory
Get-VM
Get-VMHost
Get-VMSwitch
Get-VHD -Path "D:\VMs\dc01\Virtual Hard Disks\dc01.vhdx"

# Power state
Start-VM    -Name dc01
Stop-VM     -Name dc01 -Force
Restart-VM  -Name dc01
Suspend-VM  -Name dc01

# Snapshot (checkpoint)
Checkpoint-VM -Name dc01 -SnapshotName "pre-patch-$(Get-Date -f yyyyMMdd)"
Get-VMSnapshot -VMName dc01
Restore-VMSnapshot -Name "pre-patch-20260101" -VMName dc01 -Confirm:$false
Remove-VMSnapshot  -Name "pre-patch-20260101" -VMName dc01
```

## Featured Scripts (this repo)

| Script | Purpose |
|--------|---------|
| `scripts/Enable-HyperVRole.ps1` | One-shot host preparation |
| `scripts/New-LabVM.ps1` | Parameterized VM provisioning |
| `scripts/New-VMSwitch-Lab.ps1` | Build External/Internal/Private switches |
| `scripts/Backup-VMCheckpoints.ps1` | Daily checkpoint + export |
| `scripts/Restore-VMFromExport.ps1` | Recover a VM from exported backup |
