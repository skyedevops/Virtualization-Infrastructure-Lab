# Storage Allocation

## Disk Provisioning Models

| Model | Hyper-V | VMware | Proxmox/KVM | VirtualBox |
|-------|---------|--------|-------------|------------|
| Thick / pre-allocated | Fixed VHDX | Thick provisioned, eager-zeroed | `raw` or `qcow2 -o preallocation=metadata` | Fixed-size VDI |
| Thin / dynamic | Dynamically expanding VHDX | Thin provisioned | `qcow2`, ZFS sparse, LVM-thin | Dynamic VDI |
| Differencing / linked | Differencing VHDX | Linked clones | qcow2 with backing file | Differencing/linked clones |
| RAW pass-through | Pass-through disk | Raw Device Mapping (RDM) | `--scsi0 /dev/sdb` | `VBoxManage createmedium --variant rawdisk` |

## Format Cheat Sheet

| Format | Hypervisor | Snapshots | Best for |
|--------|------------|-----------|----------|
| VHDX | Hyper-V | yes | Windows-centric |
| VMDK | VMware | yes | VMware ecosystem |
| qcow2 | KVM/Proxmox | yes | KVM + portable images |
| raw | KVM/Proxmox | only via storage layer (ZFS, LVM-thin) | Highest perf |
| VDI | VirtualBox | yes | VBox-native |
| VHD | Hyper-V (legacy) | yes | Generation-1 VMs |

## Recommended Layout

```
Hypervisor host
+-- Tier 0 NVMe                 # OS + active VM disks
|   +-- /var/lib/vz (Proxmox)
|   +-- D:\VMs       (Hyper-V / VMware on Windows)
+-- Tier 1 SATA SSD             # secondary VM disks, ISO library, exports
|   +-- /mnt/ssd, E:\ISOs
+-- Tier 2 HDD or NAS           # backups, archive
    +-- /mnt/backup, \\nas\backup
```

## Storage Backends per Hypervisor

### Hyper-V

- **Local NTFS / ReFS** - default. ReFS recommended for VHDX (integrity streams + faster fixed-size disk creation).
- **SMB 3 share** - allows VMs on a NAS; fast with RDMA.
- **Storage Spaces Direct (S2D)** - cluster-only.

```powershell
# Create a fixed-size VHDX (best perf)
New-VHD -Path "D:\VMs\db01\db01.vhdx" -SizeBytes 100GB -Fixed

# Resize online (must be SCSI, not IDE)
Resize-VHD -Path "D:\VMs\db01\db01.vhdx" -SizeBytes 150GB

# Compact a dynamic VHDX (offline)
Optimize-VHD -Path "D:\VMs\test01\test01.vhdx" -Mode Full
```

### Proxmox / KVM

- **local-lvm** (default LVM-thin) - good perf, supports snapshots on thin volumes
- **ZFS** - the lab's recommended root: built-in snapshots, send/receive, compression, scrubs
- **directory** (`local`) - simplest, qcow2 files on ext4/xfs
- **Ceph RBD** - scale-out, cluster-ready
- **NFS** - shared storage for HA

```bash
# Resize a VM disk (online)
qm resize 101 scsi0 +20G

# Convert qcow2 -> raw (fast clone for KVM)
qemu-img convert -O raw  /var/lib/vz/images/101/vm-101-disk-0.qcow2 \
                          /mnt/ssd/vm-101-disk-0.raw

# Trim/discard from inside the guest (Linux)
sudo fstrim -av

# Trim from the host on LVM-thin
lvs -a -o +discard
```

### VMware Workstation

```bash
# Defragment a growable disk (powered off)
vmware-vdiskmanager -d "D:\VMs\web01\web01.vmdk"

# Shrink (after defrag, requires VMware Tools in the guest first)
vmware-vdiskmanager -k "D:\VMs\web01\web01.vmdk"

# Grow disk by 20 GB
vmware-vdiskmanager -x 60GB "D:\VMs\web01\web01.vmdk"

# Convert split to single file
vmware-vdiskmanager -r "D:\VMs\web01\web01.vmdk" -t 0 "D:\VMs\web01\web01-single.vmdk"
```

`.vmx` performance flags:

```
scsi0:0.virtualSSD = "1"           # advertise as SSD to guest (Win disables defrag)
mainMem.useNamedFile = "FALSE"     # don't write swap to host disk for VM RAM
diskLib.dataCacheMaxSize = "32768" # KB read cache (default 0)
diskLib.dataCachePageSize = "4096"
```

### VirtualBox

```bash
# Compact a VDI (after zeroing inside guest)
VBoxManage modifymedium disk "$HOME/VirtualBox VMs/web01/web01.vdi" --compact

# Resize
VBoxManage modifymedium disk "$HOME/VirtualBox VMs/web01/web01.vdi" --resize 60000

# Convert VMDK -> VDI
VBoxManage clonemedium disk "input.vmdk" "output.vdi" --format VDI
```

## Performance Best Practices

1. **Use virtio (KVM), VMXNET3/PVSCSI (VMware), or synthetic SCSI (Hyper-V)** for disks, never IDE/emulated SATA, when the guest supports them.
2. **Enable SSD/TRIM passthrough** so deleted blocks return to the host:
   - Proxmox: `qm set 101 --scsi0 ...,discard=on,ssd=1`
   - Hyper-V: SCSI controller + ReFS / thin-provisioned VHDX automatically supports TRIM
   - VMware: `scsi0:0.virtualSSD = "1"`
3. **Separate OS, data, and swap** onto different vDisks for big VMs - simpler to grow, snapshot, or migrate.
4. **Pre-grow databases** to expected size; constant qcow2/dynamic-VHDX expansion is slow.
5. **iothread = 1** on Proxmox SCSI controllers for I/O-heavy guests.

## Capacity Planning

Daily check:

```bash
# Host-side
df -hT | grep -vE 'tmpfs|squashfs'
zpool list
lvs -a -o +data_percent

# Per-VM (Proxmox)
qm list | awk 'NR>1 {print $1}' | xargs -I{} qm config {} | grep -E '^(name|scsi|virtio|ide)'
```

Set alerts when:

- Host datastore > 80% used
- LVM-thin metadata pool > 80%
- ZFS pool > 80% (perf degrades hard above 90%)
- Snapshot delta growth > 10% of base disk in a week

## Storage Recovery Tips

| Failure | Action |
|---------|--------|
| Datastore full -> VMs paused | Free space (delete snapshots, expand LV/zpool), then `qm resume` / `Resume-VM` |
| Lost VHDX header | Open in PowerShell as raw file, restore from backup (no fsck for VHDX) |
| qcow2 corruption | `qemu-img check -r all <file>`; restore from backup if -r doesn't help |
| Accidental delete | If on ZFS - roll back the dataset snapshot; otherwise restore from backup |
| Bit-rot on RAID-5 SSDs | Run a scrub monthly; replace failing drives before they cascade |
