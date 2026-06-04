# Resource Management

Sizing VMs correctly is the difference between a snappy lab and a swap-thrashing slideshow. This section documents the lab's allocation conventions for CPU, memory, and storage on each hypervisor.

## Golden Rules

1. **Don't over-allocate vCPU** - more vCPUs than physical cores per VM creates scheduling contention. Start with `vCPU = workload baseline + 50% headroom`.
2. **Always reserve host RAM** - leave 2-4 GB for the host OS + hypervisor (Windows) or 1-2 GB (Linux). On Hyper-V/Proxmox, reserve more if you run management workloads on the host.
3. **Prefer thin/dynamic disks for non-prod** - lets you over-commit storage. Use `fstrim` / `discard` to reclaim.
4. **Use SSD-style flags** - tell the guest the underlying disk is SSD so it disables defrag and uses TRIM/DISCARD.
5. **Monitor before you scale** - measure with `Get-Counter`/`pidstat`/Proxmox graphs for a week before resizing.

## Contents

- [cpu-allocation.md](cpu-allocation.md)
- [memory-allocation.md](memory-allocation.md)
- [storage-allocation.md](storage-allocation.md)

## Sizing Cheat Sheet (Lab Defaults)

| Role | vCPU | RAM | Disk | Notes |
|------|------|-----|------|-------|
| Domain Controller | 2 | 2 GB | 60 GB | Reserve 2 GB, no dynamic memory |
| File Server | 2 | 4 GB | 100 GB + data disks | Dedupe optional |
| pfSense / OPNsense | 2 | 2 GB | 20 GB | 4 GB if running IDS/IPS |
| Web (nginx/apache) | 2 | 1-2 GB | 20 GB | |
| Database (Postgres/MariaDB) | 2-4 | 4-8 GB | 50+ GB | Fixed memory, no dynamic |
| Monitoring (Grafana+Prom) | 2 | 2 GB | 50 GB (TSDB) | |
| Test / scratch VM | 1-2 | 1 GB | 20 GB | Linked clone of golden |
| Windows 10/11 client | 2 | 4-8 GB | 60 GB | Dynamic memory OK |
| Kubernetes node | 4 | 8 GB | 80 GB | Fixed memory, swap off |
