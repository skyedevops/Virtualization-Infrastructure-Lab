# Snapshots, Backups & Recovery

Three pillars of operational survival:

1. **Snapshots** - point-in-time, on the same storage, for short-term rollback (minutes - days).
2. **Backups** - full or incremental copies on different storage, for medium-term retention (days - months).
3. **Disaster Recovery (DR)** - tested procedures to rebuild from backup when the primary site/host is gone.

> **Snapshots are not backups.** A snapshot stored on the same datastore as the source VM disappears with that datastore.

## Contents

- [snapshot-procedures.md](snapshot-procedures.md) - Per-hypervisor snapshot mechanics
- [backup-strategies.md](backup-strategies.md) - 3-2-1, scheduling, retention
- [recovery-procedures.md](recovery-procedures.md) - Restore drills + DR runbook

## Lab Policy Summary

| Asset | Snapshot | Backup | Off-site | RPO | RTO |
|-------|----------|--------|----------|-----|-----|
| Domain Controller (dc01) | daily (7d) | nightly | weekly to B2 | 24 h | 1 h |
| File Server (fs01) | daily (7d) | nightly | weekly to B2 | 24 h | 2 h |
| pfSense | weekly | nightly config export | weekly | 7 d | 30 min |
| Web/DMZ VMs | weekly | nightly | weekly | 7 d | 2 h |
| Client VMs | none | weekly | none | 7 d | best-effort |
| Lab notes / docs | n/a | git push (every commit) | git remote | 0 | 5 min |

Definitions:

- **RPO (Recovery Point Objective)** - max acceptable data loss measured in time
- **RTO (Recovery Time Objective)** - max acceptable downtime

## Tooling

| Layer | Tool |
|-------|------|
| Hyper-V snapshot/export | Native (`Checkpoint-VM`, `Export-VM`) + Windows Server Backup |
| VMware Workstation snapshot | Native via `vmrun snapshot` |
| Proxmox snapshot | `qm snapshot` / `pct snapshot` |
| Proxmox backup | `vzdump` -> NFS / Proxmox Backup Server |
| VirtualBox snapshot | `VBoxManage snapshot ... take` |
| In-guest backup (Linux) | `restic` / `borgbackup` -> S3/B2 + local NAS |
| In-guest backup (Windows) | Windows Server Backup, Veeam Agent Free |
| Off-site | rclone -> Backblaze B2 (lifecycle 90d Glacier) |

## Verification Cadence

- **Weekly**: restore a single random VM from last night's backup to an isolated network -> boot -> log in -> destroy.
- **Monthly**: full DR drill - rebuild a hypervisor from scratch on spare hardware and restore the critical-tier VMs.
- **Quarterly**: review and update this directory's runbooks.

Every drill is logged in `snapshots-backup/recovery-drills.md` (created on first run).
