# PBS initial setup

This runbook walks the operator through bringing up the Proxmox Backup
Server side of the v2.1 lab: install PBS on the Synology NAS VM,
declare it in `lab.yaml`, run `labctl pbs-init`, and confirm the first
backup.  The nightly restore-drill is in `docs/pbs-restore-test.md`.

## What gets installed and where

The lab uses a PBS VM running on the Synology NAS (see
`docs/pbs-decision.md` for the rationale).  The PBS VM:

- lives on the NAS so it benefits from the NAS's UPS + ECC RAM
- presents one datastore on the NAS's SSD tier (`/backup/pbs/main`)
  and one on the spinning rust tier (`/backup/pbs/offsite`) — both are
  ext4 on top of btrfs, dedup on, compression zstd
- is reachable from every Proxmox host on the management VLAN
  (10.10.20.0/24 in the fixture lab)

The PBS VM does **not** run the lab's workloads.  The PBS service is
on port 8007 (the default) and is **not** exposed beyond the lab VLAN.

## One-time install

1. Grab the latest PBS ISO from
   <https://www.proxmox.com/downloads/proxmox-backup-server> and
   attach it to a fresh VM on the NAS (4 vCPU, 8 GB RAM, 32 GB system
   disk is plenty; the data lives on the NAS's storage tier).
2. Install with the standard Proxmox installer.  During install set
   the management interface to a static IP inside the lab VLAN — the
   fixture lab uses `10.10.20.5/24`, gateway `10.10.20.1`.
3. After the installer reboots, set up DNS + an SSH key for the
   `root` account:

   ```bash
   # from your workstation
   ssh-copy-id -i ~/.ssh/lab_ed25519 root@10.10.20.5
   ssh root@10.10.20.5 'apt update && apt full-upgrade -y && reboot'
   ```

4. Optional: subscribe to the enterprise repo or remove the
   enterprise repo per the usual Proxmox dance.  The lab runs fine
   without a subscription.

## Declare PBS in lab.yaml

The PBS host is a *peer* of the hypervisors, not a hypervisor itself.
It goes in a separate top-level `pbs_servers:` block, distinct from
`hypervisors:`.  The block also declares the per-datastore retention
policy; both `labctl pbs-init` and the bash runbook read from here.

```yaml
pbs_servers:
  pbs01:
    host: 10.10.20.5
    ssh_user: root
    ssh_port: 22
    ssh_key: /etc/lab/ssh_key
    ssh_options: "-o StrictHostKeyChecking=no"
    datastores:
      main:
        path: /backup/pbs/main
        keep_last: 3
        keep_daily: 7
        keep_weekly: 4
        keep_monthly: 6
        prune_run: "mon..sat 02:00"
      offsite:
        path: /backup/pbs/offsite
        keep_last: 2
        keep_daily: 14
        keep_weekly: 8
        keep_monthly: 12
        prune_run: "sun 03:00"
```

Then declare which VMs are backed up to which datastore in
`backup_jobs:`.  The same `vm:` and `pbs:` values are referenced from
the `vms:` and `pbs_servers:` blocks, so the validator will catch
typos.

## labctl pbs-init

The one-shot bring-up is `pbs-init`.  It is dry-run by default; pass
`--execute` to actually call `proxmox-backup-manager` on the PBS host:

```bash
# dry-run (prints the commands it would run)
python3 scripts/python/labctl.py --lab lab.yaml pbs-init

# actually do it
python3 scripts/python/labctl.py --lab lab.yaml pbs-init --execute
```

For each datastore in `pbs_servers.<name>.datastores`, this:

1. `mkdir -p <path>/.chunks` (PBS requires the `.chunks` subdir)
2. `proxmox-backup-manager datastore create <name> <path>`
3. `proxmox-backup-manager prune-job create <name>-prune --schedule
   "<prune_run>" --keep-last N --keep-daily N ...` (or `prune-job
   update` on subsequent runs so re-runs are idempotent)

There is also a bash equivalent that doesn't need the labctl Python
dep, suitable for cron:

```bash
scripts/bash/pbs-init.sh pbs01 \
  --datastore main --path /backup/pbs/main \
  --keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --prune-run "mon..sat 02:00" \
  --execute
```

## Declare backup jobs in lab.yaml

Each `backup_jobs[]` entry becomes one `proxmox-backup-manager backup`
+ `prune` + `job create` triple.  The full triple is printed by
`labctl backup` (dry-run); with `--execute` it is run on the SOURCE
PVE node, not on PBS (the PVE streams the data into PBS over the LAN).

```bash
# Dry-run: see the commands without running them
python3 scripts/python/labctl.py --lab lab.yaml backup

# Run them
python3 scripts/python/labctl.py --lab lab.yaml backup --execute

# Or one VM at a time
python3 scripts/python/labctl.py --lab lab.yaml backup --vm web01 --execute
```

The backup command runs on the **source PVE node** for each VM, NOT
on PBS.  This is a common source of confusion: the PVE has the data,
PBS has the storage, and the PVE streams the data to PBS over the
network.  The `labctl backup` output includes a `# (run on
pve01=..., NOT on PBS)` reminder line for each job.

## Confirm the first backup

```bash
# List datastores from PBS's perspective
python3 scripts/python/labctl.py --lab lab.yaml pbs-status

# Inside PBS, list the snapshots that landed
ssh root@10.10.20.5 'proxmox-backup-manager snapshot list main:backup-web01/host/pve01'
```

The snapshot namespace is `host/<pbs-host>/<type>/<vmid>/<timestamp>`.
You should see one snapshot per job per scheduled run.

## Schedule

The `proxmox-backup-manager job create` command emitted by
`labctl backup --execute` registers a scheduled job on the **source
PVE** (in its local cron, not on PBS).  Verify with:

```bash
ssh root@pve01 'cat /etc/cron.d/proxmox-backup-manager-job-*'
```

If you ever lose the schedule, re-run `labctl backup --execute` and
the `job create` line will be re-emitted.

## What to do if PBS is unreachable

The PVE-side backup job will retry a few times then fail with a
non-zero exit code.  labctl surfaces the failure in its dry-run
output as a non-zero return code from the `backup` subcommand.  In
production you'd hook this into a monitoring system (Prometheus +
Alertmanager in the lab) — see `docs/bootstrap-test.md` for the
existing alerting wiring pattern.

Quick triage from the PVE side:

```bash
ssh root@pve01 'proxmox-backup-manager backup main:backup-web01 --vmid 100 --node pve01'
```

The error is usually one of:

- `connection refused` → PBS service is down.  `ssh root@10.10.20.5 'systemctl status proxmox-backup-proxy proxmox-backup'`.
- `permission denied` → the PVE doesn't have a PBS user/token.  Add
  one with `proxmox-backup-manager user create` on PBS and store the
  token in `/etc/pve/priv/storage/<pbshost>.enc` on the PVE.
- `no space left` → out of disk.  Check the prune-job and free space:
  `ssh root@10.10.20.5 'df -h /backup/pbs/* ; proxmox-backup-manager prune-job list'`.
