# Cross-Hypervisor Automation Scripts

This directory holds tooling that spans multiple hypervisors or is generic to any lab host.

| Path | Purpose | Runs on |
|------|---------|---------|
| `powershell/Get-LabInventory.ps1` | CSV inventory of all Hyper-V VMs on local host | Windows |
| `powershell/Invoke-LabPowerControl.ps1` | Ordered start/stop of tagged VMs | Windows |
| `bash/vm-inventory.sh` | CSV inventory of all KVM VMs + LXC CTs | Proxmox/Debian |
| `bash/lab-health.sh` | Host + VM health snapshot (exit code = severity) | Proxmox/Debian |
| `python/multi-hypervisor-report.py` | Merge per-hypervisor CSVs into one Markdown report | Any (Python 3.8+) |

## Typical Workflow

```bash
# 1. On each Hyper-V host (Windows)
.\Get-LabInventory.ps1 -OutFile C:\Reports\hyperv-$(Get-Date -f yyyyMMdd).csv

# 2. On each Proxmox node (Linux)
./vm-inventory.sh -o /tmp/proxmox-$(date +%Y%m%d).csv

# 3. Aggregate (on your workstation)
python3 multi-hypervisor-report.py \
   --hyperv  reports/hyperv-20260131.csv \
   --proxmox reports/proxmox-20260131.csv \
   --out     reports/lab-summary-20260131.md
```text

## Recommended Cron / Scheduled Tasks

| Schedule | Job |
|----------|-----|
| Every 5 min | `lab-health.sh` -> push to Prometheus alertmanager / email on non-zero exit |
| Daily 02:00 | `Backup-VMCheckpoints.ps1`, `backup-all-vms.sh`, `snapshot-rotate.sh` |
| Weekly Sun 03:00 | Full export weekly tier; off-site rsync to B2 |
| Weekly Mon 09:00 | `Get-LabInventory.ps1` + `vm-inventory.sh` + merge report |
| Monthly | DR drill: restore one random VM from off-site backup to isolated bench |

Schedulers:

- Windows: `Register-ScheduledJob` or Task Scheduler
- Linux: `systemd` timers (preferred) or `cron`
- Proxmox: built-in **Datacenter -> Backup** plus systemd timers for the scripts above
