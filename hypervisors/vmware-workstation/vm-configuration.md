# VMware Workstation - VM Configuration

This guide walks through building a production-style Linux VM from ISO. The same flow applies to Windows guests with minor changes noted inline.

## 1. Create the VM (Wizard)

1. **File -> New Virtual Machine** -> Custom (advanced)
2. **Hardware compatibility**: `Workstation 17.x` (or lowest required for portability)
3. **Guest OS install**: `I will install the OS later` (avoids Easy Install auto-config)
4. **Guest OS**: pick the closest match (Ubuntu 64-bit / Microsoft Windows Server 2022)
5. **VM name + location**: `D:\VMs\ubuntu-srv-01\`
6. **Processors**: 2 sockets x 2 cores = 4 vCPUs (adjust per workload)
7. **Memory**: 4096 MB (Linux server) / 8192 MB (Windows Server)
8. **Network type**:
   - NAT (default) for outbound-only test VMs
   - Bridged for production-like VMs on the LAN
   - Custom (VMnet1) for host-only isolation
9. **I/O controller**: LSI Logic SAS (Linux) / LSI Logic SAS or NVMe (Windows)
10. **Disk type**: NVMe for new guests, SCSI for legacy
11. **Disk**: Create new virtual disk, 40 GB, **store as single file**, allocate disk space later (thin)
12. **Customize hardware** before finishing:
    - Remove Sound Card, Printer, USB Controller if not needed
    - CD/DVD: point to your ISO
    - Add a second NIC if dual-homed
13. **Finish**.

## 2. Optimal Advanced Settings

Edit the `.vmx` file directly with the VM powered off to add:

```
# Disable annoying CPU mitigations on isolated lab VMs (improves perf)
ulm.disableMitigations = "TRUE"

# Disable side-channel side-effects logging
hypervisor.cpuid.v0 = "FALSE"

# Force time sync from host (good for short-lived test VMs)
tools.syncTime = "TRUE"

# Enable nested virtualization (needed to run Hyper-V/KVM inside)
vhv.enable = "TRUE"
vpmc.enable = "TRUE"

# Disk performance
scsi0:0.virtualSSD = "1"        # advertise as SSD to guest
mainMem.useNamedFile = "FALSE"  # reduce host disk thrash
```

## 3. Install Guest OS

1. Power on VM, boot to ISO.
2. Complete the OS installer with these standards:
   - Hostname: matches VM name (`ubuntu-srv-01`)
   - User: `labadmin` with strong password + SSH key
   - Storage: LVM for Linux, default for Windows
   - Updates: install during setup if option available
3. After install, eject the ISO (Edit VM settings -> CD/DVD -> remove or point to "Use physical drive").

## 4. Install Guest Tools

**Linux (Ubuntu / Debian):**

```bash
sudo apt update
sudo apt install -y open-vm-tools open-vm-tools-desktop
sudo systemctl enable --now open-vm-tools
```

**Linux (RHEL / Rocky / CentOS):**

```bash
sudo dnf install -y open-vm-tools
sudo systemctl enable --now vmtoolsd
```

**Windows:**

- VM menu -> Install VMware Tools -> mount ISO -> run `setup64.exe` -> Complete install -> reboot.

Verify:

```bash
vmware-toolbox-cmd -v
```

## 5. Post-Install Baseline

Apply these regardless of guest OS:

- Static IP or DHCP reservation (see `networking/` for VLAN assignments)
- Time sync (NTP)
- Hostname + FQDN
- Admin user with sudo / Administrators group
- SSH key auth (Linux) or WinRM HTTPS (Windows)
- Disable password root/Administrator login over network
- Install monitoring agent (node_exporter / Telegraf)
- Take a baseline snapshot named `clean-baseline`

## 6. Convert to Template (Golden Image)

VMware Workstation does not natively support "templates" like vCenter, but the workflow is:

1. Generalize the VM:
   - **Linux**: `sudo cloud-init clean --logs` + clear `/etc/machine-id`
   - **Windows**: `C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown`
2. Power off.
3. Mark the `.vmx` as a template by setting `templateVM = "TRUE"`.
4. Take a snapshot named `golden`.
5. Future VMs are created via **Clone -> Linked clone from `golden` snapshot**.

## 7. Linked Clone Example

```bash
vmrun clone "D:\VMs\golden-ubuntu\golden-ubuntu.vmx" \
            "D:\VMs\test-01\test-01.vmx" \
            linked \
            -snapshot=golden \
            -cloneName=test-01
```

Linked clones share the parent's base disk and only store deltas, saving 80-95% of disk space for short-lived VMs.
