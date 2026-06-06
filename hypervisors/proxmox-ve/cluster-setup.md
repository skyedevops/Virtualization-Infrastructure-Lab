# Proxmox VE - Cluster Setup

A Proxmox cluster gives you:

- Single-pane management across N nodes
- Live migration
- High Availability (HA) with shared storage
- Centralized backup orchestration

Requirements:

- 2+ nodes (3+ recommended for HA quorum)
- Same major Proxmox version on all nodes
- Low-latency network between nodes (1 GbE minimum, dedicated NIC ideal)
- Time synchronization (chrony / ntpd)

## 1. Pre-flight on Every Node

```bash
# Same time
timedatectl set-timezone UTC
systemctl enable --now chrony

# Reachable hostnames
cat /etc/hosts
# Ensure each node lists the IP+FQDN of every other node:
# 10.10.10.11  pve01.lab.local pve01
# 10.10.10.12  pve02.lab.local pve02
# 10.10.10.13  pve03.lab.local pve03

# No VMs on joiners
qm list
pct list
# Both must be empty on the nodes that will *join* the cluster.
```text

## 2. Create the Cluster (on the first node only)

```bash
pvecm create lab-cluster --link0 10.10.10.11
pvecm status
```text

`--link0` pins Corosync to the management IP. Use a dedicated 1+ GbE link if available; you can add a `--link1` for redundancy.

## 3. Join Additional Nodes

On `pve02`:

```bash
pvecm add 10.10.10.11 --link0 10.10.10.12
# enter pve01's root password when prompted
```text

Repeat on `pve03`. Verify:

```bash
pvecm nodes
pvecm status
```text

You should see `Quorate: Yes` and all nodes listed.

## 4. Shared Storage for HA

HA requires storage all nodes can write to. Options:

- **NFS** (simplest)
- **iSCSI + LVM-shared**
- **Ceph** (integrated, scale-out; needs 10 GbE for production)
- **ZFS over iSCSI**

Quick NFS example:

```bash
# Per node
pvesm add nfs shared-nfs \
  --server 10.10.99.20 --export /volume1/pve-shared \
  --content images,iso,backup,vztmpl \
  --options vers=4.1
```text

VM disks on `shared-nfs` are live-migratable across the cluster with no downtime.

## 5. Enable HA on a VM

```bash
# Mark VM 101 as HA-managed
ha-manager add vm:101 --state started --max_restart 3 --max_relocate 2

# Show HA status
ha-manager status
```text

If the node hosting VM 101 fails, the cluster reschedules it on a surviving node (assuming the disk is on shared storage).

## 6. Live Migration

```bash
# Online (running VM)
qm migrate 101 pve02 --online

# Offline
qm migrate 101 pve02
```text

GUI: select VM -> Migrate -> pick target node.

## 7. Cluster Health Checks

```bash
pvecm status              # quorum + node list
corosync-cfgtool -s       # corosync link status
ha-manager status         # HA resources
journalctl -u corosync -f # live cluster log
```text

## 8. Removing a Node

From any other node:

```bash
pvecm delnode pve03
```text

Then clean up `/etc/pve/nodes/pve03/` if it lingers. Never re-add a removed node without a fresh OS install.

## 9. Best Practices

- Always have an **odd** number of nodes (or use a QDevice for 2-node clusters).
- Dedicate one NIC to Corosync; jitter > 5 ms breaks the cluster.
- Back up `/etc/pve/` regularly (it's the cluster config DB, fuse-mounted from `/var/lib/pve-cluster/config.db`).
- Schedule one snapshot of the cluster config before any topology change.
