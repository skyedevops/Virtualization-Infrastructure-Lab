# Live-Migration & HA-Failover Runbook

> **Audience:** lab operators.  Assumes the 3-node Proxmox cluster from
> `lab.yaml` (`pve01`, `pve02`, `pve03`) and the `prod` cluster /
> `ceph-rbd` storage pool.

This runbook covers three scenarios:

1. **Planned** - move a VM from one node to another with zero downtime
   (maintenance window).
2. **HA failover** - a node dies, Proxmox HA restarts the VMs on a
   surviving node.
3. **HA drill** - simulate a node failure to verify HA actually works.

## 0. Pre-flight

```bash
# 1. Always look at HA state first.
ssh pve01 'ha-manager status'

# 2. Verify the cluster is healthy.
ssh pve01 'pvecm status'

# 3. Confirm ceph is healthy.
ssh pve01 'ceph -s'
```

If any of those return errors, **stop** - fix the underlying issue
before doing anything user-visible.

## 1. Planned live-migration

Use this for kernel updates, hardware swaps, anything where you want
the VM to keep running.

### 1.1 Single VM (labctl)

```bash
# Dry-run shows the exact `qm migrate` command first.
python3 scripts/python/labctl.py migrate --vm pfsense --target pve02
# ... review output ...
python3 scripts/python/labctl.py migrate --vm pfsense --target pve02 --execute
```

### 1.2 Single VM (raw qm)

```bash
# Live (no downtime).
ssh pve01 'qm migrate 100 pve02 online'

# Offline (stops the VM, moves disk, restarts).
ssh pve01 'qm migrate 100 pve02 offline'
```

### 1.3 All VMs off a node (bash runbook)

```bash
# Don't migrate HA-managed VMs without --force (HA will move them back).
scripts/bash/pve-live-migrate.sh \
    --all --from pve01 --to pve02 --wait
```

The `--wait` flag polls the target until every VM shows up.  Timeout
is 2 minutes per VM.

### 1.4 Things that go wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `qm migrate` hangs | VM has a local (non-shared) disk | Move disk to shared storage first: `qm move-disk <vmid> scsi0 ceph-rbd` |
| `cluster not quorate` | Network blip on corosync | Check `pvecm status`; usually self-heals in <30s |
| VM is on local-lvm | The lab.yaml `storage:` was wrong | Edit the VM: `qm set <vmid> --scsi0 ceph-rbd:N` and re-migrate |

## 2. HA failover (reactive)

This is what Proxmox HA does automatically when a node dies.  You
normally don't need to do anything - the surviving master detects the
missing node, fences it via watchdog, and restarts the VMs on the
remaining members of their HA group.

### 2.1 Watch it happen

```bash
# From your laptop, watch the cluster converge.
watch -n 2 'ssh pve01 ha-manager status'
```

You'll see lines flip from `started pve01` to `fenced pve01` to
`started pve02` over the course of 1-2 minutes.

### 2.2 If HA didn't start the VM

Sometimes a VM is "started" in HA terms but qemu didn't actually come
up.  Check on a surviving node:

```bash
ssh pve02 'ha-manager status'
# If the VM is "started" but no qemu is running:
ssh pve02 'qm list'
# Restart the resource:
ssh pve02 "ha-manager restart vm:100"
```

### 2.3 Re-join the failed node

Once the hardware is fixed and the node is back:

```bash
# From a surviving node, unfence the dead node.
ssh pve01 'ha-manager unfence pve03'

# Tell pve03 to rejoin the cluster (if it doesn't do this on its own).
ssh pve03 'systemctl restart pve-cluster'
ssh pve03 'pvecm status'
```

## 3. HA drill (proactive)

Use this to *verify* HA works before you actually need it.  Always do
a drill before going on holiday, after upgrading the cluster, and once
per quarter as a routine check.

### 3.1 Using labctl

```bash
# 1. Apply the lab so HA resources exist.
python3 scripts/python/labctl.py apply --execute --yes

# 2. Dry-run first to see what would happen.
python3 scripts/python/labctl.py drill-ha-failover --node pve02

# 3. Fence pve02 (non-destructive; the surviving nodes will
#    restart the VMs).
python3 scripts/python/labctl.py drill-ha-failover \
    --node pve02 --execute --yes

# 4. Watch the failover happen.
watch -n 2 'ssh pve01 ha-manager status'

# 5. After the drill, unfence pve02.
python3 scripts/python/labctl.py drill-ha-failover \
    --node pve02 --unfence --execute --yes
```

### 3.2 Using the bash runbook

```bash
scripts/bash/pve-ha-status.sh pve01
```

Prints a colour-coded per-node HA report and exits non-zero if any
resource isn't `started`.

### 3.3 What to verify in a drill

- [ ] VMs on the fenced node are restarted on a surviving node.
- [ ] VM services come up cleanly (ssh, app healthcheck, etc.).
- [ ] Network connectivity is intact (VLAN trunking, Ceph network,
      corosync ring).
- [ ] After unfence, the fenced node rejoins the cluster cleanly.
- [ ] `pvecm status` shows expected vote count.

## 4. Post-mortem

After a real failover or drill, log the result to
`snapshots-backup/ha-drills.md` with:

- Date / time / operator
- Why (real failure vs. drill)
- How long the failover took
- Any VMs that didn't come back up cleanly
- Any actions taken

## 5. Related

- `docs/cluster-storage-decision.md` - why we use Ceph for hot disks.
- `docs/lab-yaml-schema.md` - how `storage`, `ha`, `ha_group` are
  declared in `lab.yaml`.
- `scripts/bash/pve-ha-status.sh` - HA health check.
- `scripts/bash/pve-live-migrate.sh` - standalone migration tool.
- `scripts/python/labctl.py {migrate,ha-status,drill-ha-failover}` -
  labctl equivalents.
