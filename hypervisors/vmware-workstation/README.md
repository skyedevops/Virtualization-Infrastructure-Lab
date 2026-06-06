# VMware Workstation Pro

VMware Workstation is the desktop-class Type-2 hypervisor used in this lab for:

- Rapid OS testing (boot ISOs, evaluate distros)
- Nested virtualization (run Hyper-V or ESXi inside a VM)
- Portable lab segments that travel with the workstation
- Cross-team demos using shared VM bundles

## Version Tested

| Component | Version |
|-----------|---------|
| VMware Workstation Pro | 17.5.x |
| Host OS | Windows 11 Pro 23H2 |
| VMware Tools | 12.4.x (bundled) |

## Contents

- [installation.md](installation.md) - Install and initial configuration
- [vm-configuration.md](vm-configuration.md) - Building a VM from ISO
- [networking.md](networking.md) - VMnet0/1/8, custom networks, VLAN

## Quick Reference - `vmrun` CLI

`vmrun` lives in `C:\Program Files (x86)\VMware\VMware Workstation\` on Windows and `/usr/bin/vmrun` on Linux.

```bash
# Power state
vmrun start  "D:\VMs\ubuntu-22.vmx" nogui
vmrun stop   "D:\VMs\ubuntu-22.vmx" soft
vmrun reset  "D:\VMs\ubuntu-22.vmx"

# Snapshots
vmrun snapshot "D:\VMs\ubuntu-22.vmx" pre-update
vmrun listSnapshots "D:\VMs\ubuntu-22.vmx"
vmrun revertToSnapshot "D:\VMs\ubuntu-22.vmx" pre-update
vmrun deleteSnapshot "D:\VMs\ubuntu-22.vmx" pre-update

# List running VMs
vmrun list

# Run a command inside a guest (requires VMware Tools)
vmrun -gu root -gp <password> runProgramInGuest "D:\VMs\ubuntu-22.vmx" /usr/bin/uptime
```text

## Best Practices Used in This Lab

1. Store all `.vmx` and `.vmdk` files on a dedicated SSD partition (e.g., `D:\VMs\`).
2. Pre-allocate disks for performance-critical VMs; use growable disks for short-lived test VMs.
3. Disable side-channel mitigations only on isolated lab VMs (`ulm.disableMitigations = "TRUE"`).
4. Always install VMware Tools / open-vm-tools immediately after guest OS install.
5. Use **linked clones** for short-lived test machines built from a golden parent VM.
