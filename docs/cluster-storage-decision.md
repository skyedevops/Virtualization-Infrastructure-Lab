# Cluster Shared Storage: Ceph vs NFS

When the lab grows from a single Proxmox node to a 3-node cluster, the
biggest architectural decision is *where the VM disks live*.  Every
live-migration, every HA failover, and every shared-template feature
relies on the answer.  This document captures the trade-off for the
homelab context and records the decision.

## TL;DR

For a 3-node Proxmox cluster on commodity hardware with mixed
workload, **Ceph (RBD, 3 replicas) on the same SSDs that already host
the hypervisor** is the right call when:

- you want live-migration and HA to work without buying a NAS
- you can dedicate 2-3 SSDs per node (one for Proxmox OS, one for
  Ceph WAL/DB, one or more for Ceph OSDs)
- the cluster will run more than ~6 VMs

**NFS from a Synology / TrueNAS box** is the right call when:

- you already own a NAS with ECC RAM and a UPS
- the workload is mostly cold storage (backups, ISOs, templates,
  infrequently-running VMs) and write-throughput is not critical
- you want to keep the cluster nodes' SSDs free for hypervisor OS
  and Ceph, not VM disks

A mixed setup (Ceph for hot VM disks + NFS for backups / ISOs /
templates / PBS datastore) is the **most common homelab pattern** and
is what the rest of this repo assumes.

## The hard constraints

| Constraint | Why it matters |
|------------|----------------|
| 1 GbE (or 2.5 GbE) switch fabric | Live-migration of a running VM streams its dirty memory pages over the network; at 1 GbE, a 4 GB VM migrating at 5 GB/s of dirty pages takes minutes and stalls the workload. 10 GbE makes it boring. |
| SSDs everywhere | Spinning rust under Ceph = OSD journals fall behind, recovery takes hours, OSDs get marked out. SSDs make Ceph boring. |
| Same storage on every node | Live-migration copies memory, not disk. The disk has to be reachable from both nodes already, otherwise migration is a storage-migration, not a live-migration. |
| Shared network for cluster + storage | Proxmox Cluster (corosync) and Ceph public/cluster networks want low-latency, dedicated links. VLAN or physical separation. |

## Ceph — what you get, what it costs

**What it is.** Distributed object store. Each VM disk is replicated
across OSDs on different hosts.  In a 3-node cluster, size = (sum of
OSDs) / 3, because 3x replication.

**Pros for a homelab.**

- *No extra hardware.* The SSDs that already live in each Proxmox
  node become Ceph OSDs. You turn a 3-node cluster into a single
  storage pool without buying a NAS.
- *Live-migration is fast.* Because the disk is local on every node,
  live-migration is "memory only" — sub-second for most lab VMs.
- *Self-healing.* Lose an OSD, Ceph re-replicates to the survivors
  in the background.
- *No single point of failure.* The whole point of 3 nodes is to
  tolerate 1 host failing. NFS ties you to the NAS; Ceph doesn't.
- *Thin provisioning + snapshots + clones for free.* RBD snapshots
  are used internally by Proxmox for the backup-avoiding `qm clone`.

**Cons for a homelab.**

- *Eats SSD capacity.* 3x replication means 1 TB of usable Ceph needs
  3 TB of raw SSDs. With NVMe at ~$80/TB this is fine; with SATA
  SSDs at ~$120/TB it stings.
- *RAM overhead.* 1 GB of RAM per OSD, plus 2 GB per `mds` if you
  also use CephFS. Three 1-TB OSDs per host = 3 GB just for OSDs.
- *Tuning surface.* PG count, `osd_op_threads`, `cache_size`,
  `bluestore_cache_meta_ratio` all need numbers that depend on
  your SSD model.  Out-of-box defaults are conservative; you'll
  read the Proxmox wiki page on Ceph tuning once.
- *Network requirement.* A separate 10 GbE (or 2.5 GbE) link for the
  Ceph public network, ideally on a separate VLAN. At 1 GbE you'll
  regret it.

**Hardware sizing rule of thumb.** For 3 nodes with mixed SATA + NVMe:

- 1 NVMe per node, dedicated to the Proxmox OS install + ISO storage
- 1-2 SATA or NVMe SSDs per node, dedicated to Ceph OSDs
- 1-2 GB RAM per OSD for the OSD daemon alone

**When to skip Ceph.** If the cluster will only ever run 2-3 VMs and
the NAS is already on UPS + ECC, NFS wins on simplicity.

## NFS — what you get, what it costs

**What it is.** The NAS exports a directory via NFS. Every Proxmox
node mounts the same export as a `Storage` of type `NFS`.  All VM
disks live on the NAS; Proxmox itself lives on the local SSD.

**Pros for a homelab.**

- *Simple.* It's a Synology checkbox and an `/etc/exports` line.
- *Reuses the NAS you already have.* Most homelabbers already own
  one. Use it.
- *Capacity = NAS capacity, not sum-of-SSDs.* No 3x replication tax.
- *ZFS / Btrfs on the NAS gives you snapshots for free.* Proxmox can
  snapshot via `zfs send/receive` if the storage type is right.
- *Easier to back up.* `rsync` from the NAS to offsite is the same
  workflow whether the data is VM disks or anything else.

**Cons for a homelab.**

- *Single point of failure unless you cluster the NAS.* Standalone
  Synology = one power supply, one CPU.  Cluster quorum doesn't help
  if the NAS is gone.
- *Network is the bottleneck.* NFS over 1 GbE caps a single VM's
  disk at ~110 MB/s. Ceph with 3 SSDs on the same network can do
  3-4x that for parallel workloads.  At 10 GbE this mostly washes
  out, but 10 GbE switches are still $200+.
- *Live-migration still moves memory only, but VM disk I/O has to
  traverse the network on every read and write.*  A chatty VM (DC,
  database) will feel the latency.
- *No self-healing.* If the NAS corrupts a file, Proxmox finds out
  on the next read. ZFS scrubs help, but the VM is already
  affected.

**Hardware sizing rule of thumb.** A Synology DS923+ with 2x NVMe
cache + 4x 8 TB CMR drives in SHR-1 (~24 TB usable) is the homelab
sweet spot. Add 10 GbE NIC if your switch supports it.

## Comparison matrix

| Criterion                      | Ceph (3-replica)               | NFS from a NAS                  |
|--------------------------------|--------------------------------|---------------------------------|
| Extra hardware                 | None (reuses node SSDs)        | A NAS with UPS + ECC            |
| Single point of failure        | No (3 nodes tolerate 1 loss)  | Yes (unless the NAS is clustered) |
| Live-migration latency         | Memory only, ~1-5 s            | Memory only, but disk I/O stays network-attached |
| Sequential read (per VM)       | ~300-500 MB/s (NVMe OSDs)      | ~110 MB/s (1 GbE) / ~400 MB/s (10 GbE) |
| Random 4K IOPS                 | Tens of thousands              | Hundreds to low thousands       |
| Capacity efficiency            | 33% (3-replica)                | ~90% (RAID-5 / SHR-1)           |
| Operational complexity         | High (tuning + monitoring)     | Low (checkbox on the NAS)       |
| Failure mode                   | Silent self-heal               | Phone rings at 2 AM             |
| Best for                       | Hot VM disks, HA workloads     | Backups, ISOs, templates, cold VMs |

## The decision for *this* repo

This lab is sized for 3 Proxmox nodes on mini-PCs (N100 / Ryzen 5
class) and an existing Synology DS923+ NAS on a UPS.

| Workload            | Storage        | Why |
|---------------------|----------------|-----|
| Production VMs      | Ceph (RBD, 3x) | HA + live-migration + no single point of failure |
| ISOs / templates    | NFS (NAS)      | One-time write, read-mostly; capacity matters more than speed |
| vzdump backups      | NFS (NAS)      | Linear write, offsite-replicated; doesn't need Ceph IOPS |
| PBS datastore       | NFS (NAS)      | Dedup + incremental-forever makes this NFS-friendly |

**Cost of doing it this way:** zero extra hardware (the SSDs are
already in the nodes), but you give up 2/3 of the SSD capacity to
Ceph replication. For a 3-node cluster with 2x 1 TB SATA SSDs per
node, that's 2 TB usable for VM disks.

**Cost of *not* doing it this way:** either buy a second NAS for
HA, or accept that one host failing means restarting every VM by
hand. The whole point of v2.0 is to *not* accept that.

## Proxmox configuration sketch

```text
# On every node, after `pveceph install`:
pveceph init --network 10.10.50.0/24
pveceph mds create        # only if you also want CephFS
pveceph osd create /dev/sdb
pveceph osd create /dev/sdc
pveceph pool create vm-disks --add_storages

# Then in the Proxmox UI, Datacenter → Storage:
#   Add → RBD → id=vm-disks, pool=vm-disks, monitor=10.10.50.1;10.10.50.2;10.10.50.3
#   Add → NFS → id=nas-iso, server=10.10.20.5, export=/volume1/iso, content=iso,vztmpl
#   Add → NFS → id=nas-backup, server=10.10.20.5, export=/volume1/backup, content=backup, prune-backups=keep-last=3
```

The `labctl.py` runner picks the right storage based on the VM's
`storage:` field in `lab.yaml` (see `docs/lab-yaml-schema.md`).

## When to revisit the decision

| Trigger                                              | Re-evaluate toward |
|------------------------------------------------------|--------------------|
| Cluster grows past 6 nodes                           | Ceph (scale-out wins) |
| NAS gains 25 GbE and you start running 50+ VMs       | Either; benchmark   |
| A VM needs >1k IOPS sustained                        | Ceph with NVMe OSDs |
| You start running Kubernetes with persistent volumes | Ceph (RWO + RWX)   |
| Cost of SSDs drops below $30/TB                       | Ceph for everything |
| NAS dies and you don't want to replace it            | Ceph               |

## See also

- [lab-topology.md](lab-topology.md) — physical diagram including
  the Ceph / cluster / VM / mgmt VLAN separation.
- [hardware-requirements.md](hardware-requirements.md) — the
  mini-PC + NAS sizing behind this decision.
- [lab-yaml-schema.md](lab-yaml-schema.md) — how `labctl.py` models
  per-VM storage selection.
- [live-migration-runbook.md](live-migration-runbook.md) — what
  you actually do when a node needs maintenance.
