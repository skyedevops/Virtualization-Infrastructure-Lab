# DR Restore Flow (Scenario 2)

The "VM is gone, host is fine" recovery. Sequence diagram from
`snapshots-backup/recovery-procedures.md`.

```mermaid
sequenceDiagram
    autonumber
    actor Admin as Lab Admin
    participant Console as Hypervisor Host
    participant Storage as Backup Store<br/>(NAS or PBS)
    participant Network as VLAN 20<br/>(Servers)
    participant VM as Restored VM
    participant Smoke as Smoke Test<br/>Script

    Admin->>Console: Detect failure<br/>(alert from monitor)
    Admin->>Console: Identify target VM +<br/>last good backup
    Console->>Storage: List available backups<br/>(pvesm list / dir scan)
    Storage-->>Console: 2026-01-31T02:00:00Z

    alt Proxmox
        Console->>Console: qmrestore pbs01:backup/... <vmid>
    else Hyper-V
        Console->>Console: Restore-VMFromExport.ps1<br/>-ExportFolder ... -CopyFiles
    else VMware
        Console->>Console: robocopy backup\vm D:\VMs\vm<br/>/MIR
    else VirtualBox
        Console->>Console: VBoxManage import web01.ova<br/>--vmname web01-restored
    end

    Console->>Console: Re-attach to correct vSwitch<br/>(VLAN tag preserved)
    Console->>Console: Re-attach to correct vDisk path<br/>(storage migration if needed)

    Console->>VM: Power on
    VM->>Network: DHCP request (or static IP set)
    Network-->>VM: 10.10.20.X / 24
    VM->>VM: Mount filesystems,<br/>start services
    VM->>Smoke: Run smoke test
    Smoke->>VM: Get-Service / systemctl status
    Smoke->>Network: nslookup / Test-NetConnection
    Smoke-->>Admin: PASS / FAIL
    alt FAIL
        Admin->>Console: Roll back snapshot<br/>(proceed to Scenario 1)
    else PASS
        Admin->>Console: Update DNS /<br/>DHCP reservations
        Admin->>Console: Decommission old VM
        Admin->>Console: Log drill in<br/>recovery-drills.md
    end
```text

## Step-by-Step Time Budget

| Step | Expected |
|------|----------|
| 1. Detect + triage | 5 min |
| 2. Identify backup | 1 min |
| 3. Restore (size-dependent) | 10-30 min for 50 GB |
| 4. Re-attach network | 1 min |
| 5. Power on | 1 min |
| 6. Boot to login | 1-3 min |
| 7. Smoke tests | 5 min |
| 8. DNS / DHCP update | 5 min |
| 9. Log + ticket close | 5 min |
| **Total** | **35-55 min for critical VM** |

## Common Failure Modes During Restore

```mermaid
flowchart TD
    Start([Restore command])
    Start --> Q1{Backup file<br/>readable?}
    Q1 -- No --> A1[Restore backup store<br/>first or pull from off-site]
    Q1 -- Yes --> Q2{Compatible<br/>format?}
    Q2 -- No --> A2[Convert with qemu-img convert<br/>or VBoxManage clonemedium]
    Q2 -- Yes --> Q3{Network<br/>reachable?}
    Q3 -- No --> A3[Re-attach NIC to vSwitch<br/>check VLAN tag]
    Q3 -- Yes --> Q4{Service<br/>starts?}
    Q4 -- No --> A4[Check host keys reset,<br/>network up, DNS resolvable]
    Q4 -- Yes --> Done([RTO achieved])
```text

## Validation Checklist (executed by `Smoke` actor)

- [ ] VM boots to login prompt within expected time
- [ ] NTP within 1s of pool
- [ ] Gateway + DNS + internet reachable
- [ ] All systemd / Windows services at expected state
- [ ] Disk free > 20%
- [ ] App-specific health endpoint returns 200
- [ ] Manual transaction (POST / write / read) succeeds
