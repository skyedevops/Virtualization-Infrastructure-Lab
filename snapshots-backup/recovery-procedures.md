# Recovery Procedures

This document is the lab's **DR runbook**. Treat each section as a checklist you can follow under pressure.

## Recovery Decision Tree

```text
Is the VM running but misbehaving?
  +--> Rollback to last good snapshot (sub-second)         [Scenario 1]

Is the VM deleted or corrupted, host healthy?
  +--> Restore from nightly backup                          [Scenario 2]

Is the hypervisor host dead?
  +--> Rebuild hypervisor + restore all critical VMs        [Scenario 3]

Is the entire site lost (fire/theft/flood)?
  +--> Off-site restore on new hardware                     [Scenario 4]
```text

---

## Scenario 1 - Snapshot Rollback (Sub-Minute)

| Step | VMware | Hyper-V | Proxmox | VirtualBox |
|------|--------|---------|---------|------------|
| 1. Identify snapshot | `vmrun listSnapshots ...` | `Get-VMSnapshot -VMName web01` | `qm listsnapshot 101` | `VBoxManage snapshot web01 list` |
| 2. Power off VM | `vmrun stop ...` | `Stop-VM -Name web01 -Force` | `qm stop 101` | `VBoxManage controlvm web01 poweroff` |
| 3. Revert | `vmrun revertToSnapshot ... <name>` | `Restore-VMSnapshot -VMName web01 -Name <name>` | `qm rollback 101 <name>` | `VBoxManage snapshot web01 restore <name>` |
| 4. Power on | `vmrun start ...` | `Start-VM -Name web01` | `qm start 101` | `VBoxManage startvm web01` |
| 5. Validate | login, run smoke tests | login, run smoke tests | login, run smoke tests | login, run smoke tests |

**Time budget**: 1-3 minutes.

---

## Scenario 2 - Restore a Single VM from Backup

### Proxmox VE from PBS

```bash
# List available backups
pvesm list pbs01

# Restore to original VMID
qmrestore pbs01:backup/vm/101/2026-01-31T02:00:00Z 101 --storage local-lvm

# Or restore to a new VMID for side-by-side comparison
qmrestore pbs01:backup/vm/101/2026-01-31T02:00:00Z 999 --storage local-lvm
qm set 999 --name web01-restored
qm start 999
```text

### Hyper-V from Export

```powershell
.\hypervisors\hyper-v\scripts\Restore-VMFromExport.ps1 `
   -ExportFolder "E:\Exports\dc01_20260131" `
   -NewVMName "dc01-restored" `
   -SwitchName "vSwitch-Internal" `
   -CopyFiles
Start-VM -Name dc01-restored
```text

### VMware Workstation from filesystem copy

```powershell
robocopy "\\nas\backup\workstation\20260131\web01" "D:\VMs\web01" /MIR /MT:16
# Open the .vmx in Workstation -> "I Copied It" when prompted for UUID
vmrun start "D:\VMs\web01\web01.vmx" nogui
```text

### VirtualBox from OVA

```bash
VBoxManage import /mnt/backup/vbox/20260131/web01.ova --vsys 0 --vmname web01-restored
VBoxManage startvm web01-restored --type headless
```text

**Time budget**: 10-30 minutes depending on VM size + network.

---

## Scenario 3 - Hypervisor Host Rebuild

Assume `pve02` is dead. Spare hardware is available.

1. **Diagnose** - confirm the host is unrecoverable (cannot POST, disk failure, OS corruption beyond fsck).
2. **Reinstall hypervisor** - boot the install ISO on spare hardware, restore the same hostname + management IP. (See `hypervisors/<x>/installation.md`.)
3. **Rejoin storage / cluster**:
   - Proxmox: `pvecm add <existing-node-ip>`, then re-add to PBS/NAS shares.
   - Hyper-V: re-add to Failover Cluster if applicable; remap SMB/iSCSI shares.
4. **Restore VMs** in priority order:
   - Critical (dc01, pfSense) first.
   - Important next.
   - Convenience last (or skip if rebuildable from golden image).
5. **Network sanity**: validate IPs, VLAN tags, firewall rules; ping each gateway.
6. **Run smoke tests**: AD replication health, DNS resolution, DHCP leases.

**Time budget**: 2-4 hours for a 10-VM lab with good runbooks.

---

## Scenario 4 - Full Off-Site Restore

Site is lost. New hardware obtained.

1. **Procure** - 1 host capable of running the critical VMs. Specs in `docs/hardware-requirements.md`.
2. **Provision base OS** - Proxmox VE or Hyper-V on the new box.
3. **Re-attach off-site** - install `rclone`, configure the B2 remote with stored credentials. Pull the latest backups to local disk.
4. **Restore critical VMs** (dc01, pfSense first - everything else depends on AD + DNS + routing).
5. **Re-IP if needed** - if WAN address changed, update DNS records, VPN endpoint, pfSense config.
6. **Bring up tier 1, 2, 3** in order. Validate each before moving on.
7. **Update documentation** - capture lessons learned in `recovery-drills.md`.

**Time budget**: 1-2 days (depends mostly on download speed for off-site backups).

---

## Standard Smoke Tests After Recovery

### Generic

- [ ] VM boots to login prompt within expected time
- [ ] NTP sync clean (within 1s of pool)
- [ ] Network reachable: gateway, DNS, internet
- [ ] All services from `systemctl --failed` / `Get-Service` non-running expected only
- [ ] Disk free > 20%

### Domain Controller (dc01)

```powershell
Get-ADForest
Get-ADDomain
dcdiag /v /c
repadmin /replsummary
nslookup dc01.lab.local
nslookup -type=SRV _ldap._tcp.lab.local
```text

### File Server (fs01)

```powershell
Get-SmbShare
Test-Path "\\fs01\public"
Get-SmbConnection
```text

### pfSense

- LAN gateway pings
- DHCP leases active
- Firewall logs flowing
- VPN connects

### Database / app

- App-specific health check endpoint returns 200
- Last 5 minutes of logs free of errors
- Manual transaction succeeds (e.g., POST a test order)

---

## Drill Log Template

After each drill or real recovery, append to `recovery-drills.md`:

```markdown
## YYYY-MM-DD - <Scenario> - <VM(s)>
- Trigger: planned drill / real incident
- Start: HH:MM
- Steps deviated: ...
- Issues encountered: ...
- End: HH:MM
- RTO actual: Xm  (target: Ym)
- RPO actual: X h  (target: Y h)
- Action items: ...
```text

Reviewing the drill log quarterly is where most of the runbook improvements come from.
