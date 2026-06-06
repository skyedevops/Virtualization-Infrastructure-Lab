# Memory Allocation

Memory is the resource that most often kills a lab. Disks fill up gracefully; CPU contention just slows things down; **RAM exhaustion crashes guests or sends the host into swap**.

## Allocation Models

| Model | When to use | Pros | Cons |
|-------|-------------|------|------|
| **Static / Fixed** | Databases, AD DCs, latency-sensitive | Predictable perf, no ballooning surprises | No oversubscription headroom |
| **Dynamic (Hyper-V)** | Mixed Windows lab | Hands back unused RAM | Some apps misreport memory pressure |
| **Memory Ballooning (KVM/VMware)** | General-purpose lab | Reclaim from idle VMs | Slower than fixed when balloon shrinks |
| **KSM (Kernel Samepage Merging)** | Dense same-OS labs | Massive savings if many identical guests | CPU cost; security side-channel concerns |

## Hypervisor-Specific Controls

### Hyper-V Dynamic Memory

```powershell
Set-VMMemory -VMName web01 `
             -DynamicMemoryEnabled $true `
             -MinimumBytes  1GB `
             -StartupBytes  2GB `
             -MaximumBytes  4GB `
             -Buffer 20 `
             -Priority 50
```text

- **StartupBytes**: required at power-on (must be available)
- **MinimumBytes**: can be reclaimed down to this floor
- **MaximumBytes**: ceiling Hyper-V will grow to under pressure
- **Buffer**: % headroom Hyper-V keeps free in the guest
- **Priority**: 0-100; higher wins when host is constrained

**Disable** dynamic memory for: AD DCs, SQL Server, Exchange, Linux guests with kernel < 3.x.

### Proxmox / KVM (Ballooning)

```bash
# Fixed
qm set 101 --memory 4096 --balloon 0

# Ballooning min/max (current..target..max)
qm set 101 --memory 4096 --balloon 1024
# 1024 MB min, 4096 MB max. Hypervisor inflates the balloon driver in the guest
# to claim memory back when other VMs need it.

# Enable KSM (host-side, /etc/default/ksmtuned)
systemctl enable --now ksmtuned
```text

Verify balloon driver inside the guest:

```bash
# Linux
lsmod | grep balloon
free -m

# Windows: virtio-balloon driver from virtio-win ISO + Services -> "VirtIO Balloon"
```text

### VMware Workstation

```text
memsize = "4096"
sched.mem.min = "1024"          # reservation MB
sched.mem.minSize = "2048"      # min on resume
sched.mem.maxSize = "8192"      # cap
sched.mem.shares = "normal"
mem.hotadd = "TRUE"
```text

GUI: VM Settings -> Memory + Memory limit slider.

### VirtualBox

VirtualBox does not over-commit memory - allocation is fixed at VM start.

```bash
VBoxManage modifyvm "web01" --memory 4096 --vram 64
# Optional: page fusion (KSM-like, Windows hosts only)
VBoxManage modifyvm "web01" --pagefusion on
```text

## Sizing Heuristics

| Workload | RAM baseline | Notes |
|----------|--------------|-------|
| AD DC | 2 GB | Add 256 MB per 1000 users |
| DNS-only | 512 MB | |
| File server | 2-4 GB | More = bigger cache |
| Web (nginx) | 256-512 MB | Per worker pool tuning |
| PostgreSQL | 1 GB + (db size * 0.25), up to 8 GB | `shared_buffers` ~ 25% RAM |
| Redis | size of dataset + 20% | |
| Kubernetes node | 4 GB | 1 GB system + 2-3 GB for pods |
| ELK / Splunk indexer | 8 GB+ | Heap = 50% RAM, capped at 31 GB |

## Host Reservations

Always leave the hypervisor host **enough RAM to breathe**:

| Host OS | Reserve |
|---------|---------|
| Windows Server (Hyper-V) | 2 GB + 1 GB per 16 GB total |
| Windows 11 (Workstation/VBox) | 4 GB minimum |
| Linux (Proxmox/KVM) | 1 GB + 0.5 GB per 16 GB total |
| Proxmox with ZFS root | additional ARC max - set `zfs_arc_max` to ~25% of host RAM |

ZFS ARC tuning on Proxmox:

```bash
echo "options zfs zfs_arc_max=4294967296" > /etc/modprobe.d/zfs.conf   # 4 GB
update-initramfs -u -k all
reboot
```text

## Monitoring Memory Pressure

| Tool | Indicator | Threshold |
|------|-----------|-----------|
| `free -m` (Linux) | `available` column | > 10% total |
| `vmstat 5` | `si`/`so` swap in/out | should be ~0 |
| `Get-Counter '\Memory\Available MBytes'` | available MB | > 1024 |
| Proxmox UI / RRD | host memory chart | < 90% usage |
| Hyper-V perf | `\Hyper-V Dynamic Memory VM(*)\Average Pressure` | < 100 |

When pressure climbs:

1. Identify the largest VMs by RSS (`ps_mem`, Task Manager).
2. Lower `MaximumBytes` or `--balloon` floor on test VMs.
3. Add RAM to the host (cheapest perf upgrade in a lab).
