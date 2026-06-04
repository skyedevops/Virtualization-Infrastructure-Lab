# CPU Allocation

## Physical vs Virtual CPU

| Term | Meaning |
|------|---------|
| Physical core | one execution unit on the die |
| Logical core (thread) | hyperthread - shares execution units with its sibling |
| pCPU | one logical core visible to the hypervisor |
| vCPU | one logical CPU visible to a guest |

Hypervisors schedule vCPUs onto pCPUs. With 8 pCPUs you can run 16+ vCPUs **total**, but every individual VM with N vCPUs needs N pCPUs available *simultaneously* to make progress (co-scheduling). Over-allocating a single VM is worse than over-committing across many small VMs.

## Recommended Ratios

| Workload pattern | vCPU : pCPU ratio |
|------------------|-------------------|
| Idle / dev / test | up to 4:1 |
| Mixed lab (this lab) | 2:1 to 3:1 |
| Latency sensitive (databases, telephony) | 1:1 |
| Real-time / SLA workloads | dedicated cores |

Track host saturation with:

- Linux/KVM: `mpstat -P ALL 5`, `vmstat 1`, `pidstat -u 5`, Proxmox graphs
- Windows/Hyper-V: `Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 5 -MaxSamples 12`

## Per-Hypervisor Settings

### Hyper-V

```powershell
# Sockets / cores / threads exposure
Set-VMProcessor -VMName web01 `
                -Count 4 `
                -Reserve 0 -Maximum 100 `
                -RelativeWeight 100 `
                -ExposeVirtualizationExtensions $false

# Compatibility for live migration across CPU generations
Set-VMProcessor -VMName web01 -CompatibilityForMigrationEnabled $true

# NUMA spanning (default on, disable for NUMA-sensitive workloads)
Set-VMHost -NumaSpanningEnabled $false
```

### Proxmox / KVM

```bash
# Set cores, sockets, CPU model
qm set 101 --sockets 1 --cores 4 --cpu host

# CPU pinning to NUMA node 0
qm set 101 --affinity 0-3

# Limit / weight
qm set 101 --cpulimit 2.0      # cap at 2 cores of CPU time
qm set 101 --cpuunits 1024     # relative weight (default 1024)
```

`--cpu host` exposes every CPU flag (best perf), but blocks live migration to a host with a different CPU. Use `--cpu kvm64` or a named model (e.g. `--cpu Cascadelake-Server`) when migration matters.

### VMware Workstation

In **VM Settings -> Processors**:

- **Number of processors** (sockets)
- **Number of cores per processor**

`.vmx` keys:

```
numvcpus = "4"
cpuid.coresPerSocket = "2"
sched.cpu.min = "0"          # reservation MHz
sched.cpu.max = "0"          # cap MHz (0 = no cap)
sched.cpu.shares = "normal"  # low | normal | high | <int>
```

### VirtualBox

```bash
VBoxManage modifyvm "web01" --cpus 4 --cpuhotplug on
VBoxManage modifyvm "web01" --cpu-profile host          # expose host CPU
VBoxManage modifyvm "web01" --cpuexecutioncap 80        # 80% of one core
VBoxManage modifyvm "web01" --paravirtprovider kvm      # for Linux guests
```

## CPU Tuning Best Practices

- Match `cores per socket` to the physical NUMA node count for big VMs.
- Disable hypervisor enforced CPU mitigations (Spectre/Meltdown) **only on isolated lab VMs** if you need the perf - this is a security trade-off.
- For real-time / latency labs (e.g., VoIP), use CPU pinning and isolate cores from the host scheduler (`isolcpus=` kernel param + `irqbalance` exclusion).
- Watch the **CPU ready %** metric in VMware/Proxmox - anything over 5% sustained means the VM is waiting on pCPU.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| One VM at 100% but app slow | Single-threaded workload, vCPU count irrelevant | Profile the app, scale vertically (faster cores) |
| All VMs slow when one VM busy | Over-commit + co-scheduling | Lower vCPU on the noisy VM |
| Live migration fails "incompatible CPU" | `--cpu host` on Proxmox | Switch to a named CPU model |
| BSOD / kernel panic after sysprep | CPU mask changed | Reset compatibility flag or sysprep again on target host |
