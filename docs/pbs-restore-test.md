# PBS nightly restore drill

The restore drill is the only test that actually proves backups work
end-to-end.  `labctl pbs-init` and `labctl backup --execute` together
just confirm the WRITE path; `pbs-restore-test.sh` confirms the READ
path too, which is the one that matters at 03:00 when the datacenter
is on fire.

## What it does

`scripts/bash/pbs-restore-test.sh` (or the `pbs-restore-test`
subcommand in `labctl`):

1. Picks one backup at random from the last 7 days, in the named
   datastore.
2. Restores it to a `restore-test-<vmid>` VM on the isolated
   `vmbr1` bridge (assumed to be a separate VLAN with no production
   traffic).
3. Boots the test VM, waits up to 2 minutes for the QEMU guest agent
   to come up.
4. Optionally runs a `curl` smoke test inside the guest.
5. Tears down the test VM in the EXIT trap so we don't leak restore
   VMs.

The script writes a timestamped log line to
`/var/log/pbs-restore-test.log` for every step, and exits non-zero if
any step fails.

## How to run it

From the PVE host (where the real `qm` and `proxmox-backup-manager`
binaries live), with `LAB` pointing at the rendered lab:

```bash
# one-off, dry-run (just prints the restore command)
LAB=lab.yaml scripts/bash/pbs-restore-test.sh --datastore pbs01/main

# one-off, full run including the actual qmrestore
LAB=lab.yaml scripts/bash/pbs-restore-test.sh --datastore pbs01/main --execute

# with a smoke test (curl GET inside the guest after boot)
LAB=lab.yaml scripts/bash/pbs-restore-test.sh \
    --datastore pbs01/main --execute \
    --smoke-test http://localhost/
```

Or from `labctl`:

```bash
python3 scripts/python/labctl.py --lab lab.yaml pbs-restore-test --pbs pbs01 --datastore main
```

The labctl version shells out to the same bash runbook on the PBS
host, so they exercise the same code path.

## What success looks like

A passing run leaves this in `/var/log/pbs-restore-test.log`:

```text
2026-01-15T03:00:01+00:00 [bash] datastore: pbs01/main
2026-01-15T03:00:01+00:00 [bash] picked snapshot: host/pbs01/backup/100/2026-01-14T22:13:55Z
2026-01-15T03:00:01+00:00 [bash]   vmid=100  snap=2026-01-14T22:13:55Z
2026-01-15T03:00:01+00:00 [bash] restoring to test VM vmid=9100 name=restore-test-100 bridge=vmbr1
2026-01-15T03:00:35+00:00 [bash] waiting for QEMU guest agent on vmid=9100 ...
2026-01-15T03:01:12+00:00 [bash] agent is up after 40s
2026-01-15T03:01:13+00:00 [bash] [OK] restore-test of host/pbs01/backup/100/2026-01-14T22:13:55Z passed
2026-01-15T03:01:13+00:00 [bash] tearing down test VM vmid=9100
```

If `--smoke-test URL` is set, you also get `[OK] smoke test`.

## What failure looks like

| Symptom in log | Likely cause | Fix |
| --- | --- | --- |
| `[FAIL] no snapshots in pbs01/main from the last 7 days` | Backups are not landing, or the scheduler is broken | Check `ssh pve01 'proxmox-backup-manager job list'`, look at PBS's `tasks/` for failed backups |
| `[FAIL] qmrestore failed` | Bad snapshot key, or PBS's namespace doesn't match what qmrestore expects | Run `qmrestore` manually with the printed command and look at the error |
| `[FAIL] guest agent never came up` after 2 min | The restored VM doesn't have the QEMU guest agent enabled, or it can't reach the lab VLAN | `qm set <vmid> --agent 1` and check the network bridge is on the right VLAN |
| `[FAIL] smoke test failed` | The app inside the guest is not listening on the smoke-test URL | SSH into the test VM (`qm terminal <vmid>`) and curl manually; check the app's logs |

All failure modes exit 1, so the cron entry below will surface them
in monitoring.

## Schedule

Add to the PVE host's `/etc/cron.d/`:

```cron
# Nightly PBS restore drill - if this fails, alerts fire
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LAB=/etc/lab/lab.yaml

# Run at 03:15 (after the 03:00 backup window)
15 3 * * * root /usr/local/bin/pbs-restore-test.sh --datastore pbs01/main --execute >> /var/log/pbs-restore-test.log 2>&1 || echo "pbs-restore-test FAILED on $(date -Is)" | /usr/bin/mail -s "PBS restore drill failed" alerts@lab.local
```

(The actual mailer / alerting hook is the same one wired up for the
v1.4 e2e test — see `docs/bootstrap-test.md`.)

## Cleanup

The script's EXIT trap destroys the test VM, so nothing accumulates.
If a previous run was killed and left a `restore-test-*` VM behind:

```bash
# nuke any leftover test VMs
for vmid in $(qm list | awk '/^restore-test-/ {print $1}'); do
  qm stop $vmid 2>/dev/null; qm destroy $vmid
done
```

The `restore-test-` prefix on the name makes it easy to find them.

## Limitations

- The test only restores ONE snapshot per run, picked at random.  If
  every snapshot in the last 7 days is bad, the test will still
  report pass as long as one of them restores successfully.  Pair
  with `promox-backup-manager verify` (which hashes all chunks) for
  a stronger guarantee.
- The QEMU guest agent must be enabled in every VM the script might
  pick.  The `vms[].notes` field in `lab.yaml` is a good place to
  record which VMs are missing the agent so they get fixed.
- The test does not verify the data inside the guest, only that the
  guest boots and (optionally) that a single URL returns 200.  For
  critical workloads, add a more thorough application-level check
  via `--smoke-test`.
