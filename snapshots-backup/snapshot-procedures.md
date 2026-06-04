# Snapshot Procedures

## When to Snapshot

- **Before** any non-trivial change: OS upgrade, patching, schema change, software install, config rewrite.
- **Before** running an untrusted installer or script.
- **After** a known-good state (the "clean-baseline" / "golden" snapshots).

## When NOT to Snapshot

- As a long-term backup. Snapshots grow, fragment, and tie the VM to a single disk/host.
- On busy production databases without quiescing - prefer application-consistent backups (VSS for Windows, `pg_dump` etc. for Postgres).
- More than a handful per VM. Long chains hurt performance and complicate restores.

## Naming Convention

`<purpose>-YYYYMMDD-HHMM` e.g. `pre-kernel-bump-20260131-2100`.

Automated snapshots use the prefix `auto-` (`auto-daily-...`, `auto-weekly-...`) so retention scripts can target them safely.

---

## VMware Workstation

```bash
# Take
vmrun snapshot "D:\VMs\web01\web01.vmx" "pre-deploy-$(date +%Y%m%d-%H%M)"

# List
vmrun listSnapshots "D:\VMs\web01\web01.vmx"

# Revert (powers VM off automatically)
vmrun revertToSnapshot "D:\VMs\web01\web01.vmx" "pre-deploy-20260131-2100"

# Delete (merges deltas back into base)
vmrun deleteSnapshot "D:\VMs\web01\web01.vmx" "pre-deploy-20260131-2100"
```

GUI: VM -> Snapshot -> Snapshot Manager.

---

## Hyper-V

```powershell
# Take (production checkpoint = app-consistent w/ VSS by default)
Checkpoint-VM -Name web01 -SnapshotName "pre-deploy-$(Get-Date -f yyyyMMdd-HHmm)"

# List
Get-VMSnapshot -VMName web01

# Restore
Restore-VMSnapshot -Name "pre-deploy-20260131-2100" -VMName web01 -Confirm:$false

# Delete
Remove-VMSnapshot -Name "pre-deploy-20260131-2100" -VMName web01
```

Switch between Production (default, VSS / app-consistent) and Standard (crash-consistent) checkpoints:

```powershell
Set-VM -Name web01 -CheckpointType Production    # default
Set-VM -Name web01 -CheckpointType Standard      # crash-consistent only
```

---

## Proxmox VE

```bash
# Take (KVM)
qm snapshot 101 "pre-deploy-$(date +%Y%m%d-%H%M)" --description "Pre-app-deploy"

# Take (LXC)
pct snapshot 200 "pre-deploy-$(date +%Y%m%d-%H%M)"

# List
qm listsnapshot 101
pct listsnapshot 200

# Rollback
qm rollback 101 pre-deploy-20260131-2100
pct rollback 200 pre-deploy-20260131-2100

# Delete
qm delsnapshot 101 pre-deploy-20260131-2100
pct delsnapshot 200 pre-deploy-20260131-2100
```

To include guest RAM in a KVM snapshot, add `--vmstate 1` (requires storage that supports it, e.g. ZFS/qcow2).

Automated daily/weekly snapshots are scheduled by `hypervisors/proxmox-ve/scripts/snapshot-rotate.sh` via a systemd timer:

```ini
# /etc/systemd/system/snapshot-rotate.service
[Unit]
Description=Lab snapshot rotation
After=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/snapshot-rotate.sh
```

```ini
# /etc/systemd/system/snapshot-rotate.timer
[Unit]
Description=Daily snapshot rotation @ 03:00

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

---

## VirtualBox

```bash
# Take
VBoxManage snapshot "ubuntu-01" take "pre-deploy-$(date +%Y%m%d-%H%M)" \
  --description "Pre application install" --live

# List
VBoxManage snapshot "ubuntu-01" list --details

# Restore current branch (must be powered off)
VBoxManage snapshot "ubuntu-01" restore "pre-deploy-20260131-2100"

# Delete
VBoxManage snapshot "ubuntu-01" delete  "pre-deploy-20260131-2100"
```

`--live` lets you snapshot a running VM without pausing (slight perf hit during the take).

---

## Snapshot Health Checklist

Run weekly:

| Check | Command | Pass criteria |
|-------|---------|---------------|
| Snapshot chain length | `qm listsnapshot <id>` / `Get-VMSnapshot` / `vmrun listSnapshots` | <= 5 per VM |
| Snapshot age | metadata | no `auto-daily-*` older than 7 days |
| Datastore free space | `df -h`, `Get-PSDrive` | >= 20% free |
| Hypervisor logs | `journalctl -u pveproxy`, Hyper-V event log | no snapshot errors |

Long snapshot chains are the #1 cause of "my VM disk is suddenly huge" tickets. Prune ruthlessly.
