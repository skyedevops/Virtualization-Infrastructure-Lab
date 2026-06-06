# Proxmox Backup Server: deployment decision

Once the 3-node cluster from v2.0 is up, every VM on it needs a
backup target.  Proxmox Backup Server (PBS) is the obvious choice -
deduplicated, encrypted, incremental-forever, RESTORE-TESTABLE, all
native to the same vendor.  The decision is *where PBS itself runs*.

## TL;DR

For this lab, **PBS as a VM on the existing Synology NAS (XPenology
or a dedicated DSM PBS app), backed by an NFS-exported dedup pool**,
is the right call.  Rationale:

- Synology DSM has a first-party **Synology PBS package** that is
  functionally equivalent to bare-metal PBS for the workload this lab
  needs (4-12 VMs, ~500 GB total)
- A Synology **dedicated dedup pool** + **ECC RAM** + **UPS** already
  covers the prerequisites for safe long-term backups
- Zero new hardware, zero new rack space, zero new power budget
- The lab NAS already does the role of "appliance" for cold storage

A **dedicated mini-PC running bare-metal PBS** is the right call when:

- you need more than 1 Gbps of backup ingest (10 GbE mini-PC with NVMe
  datastore)
- the NAS cannot spare CPU/RAM for the dedup fingerprint index
- the lab needs to back up > 20 TB of VMs

A **PBS VM on the Proxmox cluster itself** is the wrong call for a
homelab and we deliberately reject it (chicken-and-egg, plus the
cluster's own VMs need to be backed up *off-cluster*).

## The hard constraints

| Constraint | Why it matters |
|------------|----------------|
| PBS datastore must be **off-cluster** | The whole point of backups is "what if the cluster is gone".  If PBS is a VM on the cluster, the cluster dying takes the backups with it. |
| PBS datastore must be **deduplication-capable** | Backing up 4-12 VMs with full daily snapshots adds up fast.  A dedup ratio of 5x is typical for lab workloads, so a 2 TB dedup pool = 10 TB of "logical" backups. |
| PBS host must be **always-on, low-noise** | Backups are scheduled; missing the window is silent data loss.  The host must be on a UPS and not subject to vacation-power-down. |
| PBS host must have **enough RAM for the chunk index** | PBS keeps a fingerprint of every 4 MB chunk in RAM.  Rough rule: 1 GB of index per 1 TB of unique data.  Plan for 8-16 GB if you have 5-10 TB unique. |
| PBS host must be **reachable from every cluster node** | Each PVE node pulls from the datastore to restore, so a slow path (1 GbE shared with VMs) is fine for restore but **not** for daily ingest of multiple VMs. |

## The three options, side by side

### Option A - PBS VM on the Synology NAS (RECOMMENDED)

- **Hardware:**  Synology RS818+ / DS920+ / similar (existing)
- **PBS install:**  Synology PBS package from Package Center (one
  click, runs as a container under DSM) OR a VM running bare-metal
  PBS in Synology Virtual Machine Manager (VMM)
- **Datastore storage:**  Existing SHR / Btrfs dedup volume on the NAS
  spindles (or an SSD cache + spindles tier for the chunk store)
- **Backup ingest path:**  1 GbE NAS, sufficient for ~5 VMs at a time
- **Pros:**  zero new hardware, leverages existing UPS / dedup / ECC,
  one less thing to administer
- **Cons:**  backup window competes with other NAS workloads (media
  streaming, file shares); single point of failure unless the NAS
  itself is HA (it isn't)
- **Estimated cost:**  $0 (existing hardware); ~5W extra power

### Option B - Dedicated mini-PC running bare-metal PBS

- **Hardware:**  Intel N100 / N305 mini-PC, 16-32 GB RAM, 1-2 TB NVMe
  for the chunk store
- **PBS install:**  Bare-metal from the official ISO, headless
- **Datastore storage:**  Local NVMe (fast, low latency, no network
  hop)
- **Backup ingest path:**  1 GbE / 2.5 GbE, dedicated
- **Pros:**  fastest ingest path, fully isolated, scalable to 10+ Gbps
  with 10 GbE NIC
- **Cons:**  new hardware ($400-800), needs a UPS outlet, another
  device to patch / monitor / back up
- **Estimated cost:**  $500 + ~10W power + a UPS outlet

### Option C - PBS VM inside the Proxmox cluster (REJECTED)

- **Hardware:**  none (a VM on the cluster itself)
- **PBS install:**  Standard PBS ISO, install in a VM
- **Datastore storage:**  ceph-rbd or local-lvm on the cluster
- **Backup ingest path:**  Loopback, basically free
- **Pros:**  no new hardware
- **Cons (fatal):**
  1. **The cluster is what we are backing up.** If the cluster dies
     (ceph loss, quorum loss, datacenter PSU fault), the backups die
     with it. The backups must be on a host that survives the failure
     of every PVE node.
  2. The PBS VM's ceph-rbd datastore is replicated to all cluster
     nodes, multiplying the actual disk usage by 3x for the dedup
     benefit. Inefficient.
  3. Restore-test (see `docs/pbs-restore-test.md`) becomes impossible:
     you can't "boot the restore-test VM on isolated VLAN" without
     already having the cluster, which is the failure mode we are
     testing for.
- **Verdict:**  Wrong abstraction. Rejected.

## Why Option A wins for *this* lab

1. **NAS is already there, already on a UPS, already on a 1 GbE
   trunk.** The hard work (chassis, RAID, dedup, ECC) is done. PBS is
   just another package on it.
2. **Backup ingest in this lab is small** (4-12 VMs, peak ~50 GB/day
   of new data after dedup). A 1 GbE NAS is comfortable at 100 MB/s
   of ingest, which finishes the daily window in 10 minutes.
3. **Restore-test** (the v2.1 deliverable that catches silent
   corruption) is much easier when the backup store is reachable from
   the laptop on a separate VLAN - which the NAS already is.
4. **Capacity headroom is free.** The Synology DS920+ has 4 bays at
   8 TB each = 24 TB raw, ~16 TB usable in SHR. The PBS datastore
   needs ~2 TB now and ~5 TB in 2 years. We're not even close to
   filling the box.
5. **If PBS-on-NAS turns out to be the wrong call**, we can promote
   it to Option B (mini-PC) later without losing data: PBS datastore
   migration is a `proxmox-backup-manager datastore move` away.

## What this means for the lab

- `lab.yaml` will declare a `pbs01` host with `type: proxmox` and a
  separate `backups:` block defining the datastore, schedule, and
  per-VM retention.
- `labctl.py` will gain a `backup` subcommand that:
  - prints the vzdump / proxmox-backup-manager commands
  - validates that the PBS host is reachable
  - optionally executes the backup of one VM (`--vm X`)
  - supports the `restore-test` workflow (see
    `docs/pbs-restore-test.md`)
- A new fake-pbs container + shim will back the integration test (the
  fake-pbs shim implements the subset of PBS API the labctl uses:
  `datastore list`, `snapshot list`, `prune`, `restore-test`).

## Related

- `docs/cluster-storage-decision.md` - Ceph vs NFS for *VM disks*.
  This doc is the *backups* analog.
- `docs/pbs-setup.md` - the actual setup runbook (deferred to step
  8.4).
- `docs/pbs-restore-test.md` - nightly restore-test runbook (deferred
  to step 8.4).
- `https://pbs.proxmox.com/docs/` - the upstream PBS docs.
