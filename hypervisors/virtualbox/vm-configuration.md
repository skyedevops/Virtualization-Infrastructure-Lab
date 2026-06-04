# VirtualBox - VM Configuration

This guide shows both the GUI workflow and a fully scripted `VBoxManage` build for a Linux VM. Adapt to Windows by changing `--ostype` and disabling EFI for legacy guests.

## 1. GUI Quick-Create

1. **Machine -> New**
2. Name: `ubuntu-srv-01`, Folder: default, ISO: pick your Ubuntu ISO.
3. Tick **Skip Unattended Install** unless you want VBox to inject answer files.
4. **Hardware**: 4 GB RAM, 2 vCPU.
5. **Disk**: 40 GB, VDI, dynamically allocated.
6. **Settings** before first boot:
   - **System -> Motherboard**: enable EFI (modern Linux/Windows)
   - **System -> Processor**: enable PAE/NX, VT-x/AMD-V nested if needed
   - **Display**: VMSVGA, 128 MB VRAM, **enable 3D** only if guest needs it
   - **Network -> Adapter 1**: NAT Network "LabNet"
   - **Network -> Adapter 2**: Host-only "vboxnet0" (for SSH from host)
   - **Shared Folders**: optional, automount if guest additions are installed
7. **Start** -> install OS as usual.

## 2. Scripted Build with `VBoxManage`

```bash
NAME="ubuntu-srv-01"
ISO="$HOME/ISOs/ubuntu-22.04.4-live-server-amd64.iso"
DISK_GB=40
RAM=4096
CPUS=2
HDD_PATH="$HOME/VirtualBox VMs/$NAME/$NAME.vdi"

# 1. Create + register VM
VBoxManage createvm --name "$NAME" --ostype "Ubuntu_64" --register

# 2. CPU / RAM / firmware
VBoxManage modifyvm "$NAME" \
  --cpus $CPUS --memory $RAM \
  --firmware efi \
  --rtcuseutc on \
  --boot1 dvd --boot2 disk --boot3 none --boot4 none \
  --nic1 natnetwork --nat-network1 LabNet --nictype1 virtio \
  --nic2 hostonly --hostonlyadapter2 vboxnet0 --nictype2 virtio \
  --audio none --usb off \
  --graphicscontroller vmsvga --vram 64 --accelerate3d off

# 3. Storage controllers
VBoxManage storagectl "$NAME" --name "SATA"  --add sata --controller IntelAhci --portcount 4
VBoxManage storagectl "$NAME" --name "IDE"   --add ide

# 4. Disk
VBoxManage createmedium disk --filename "$HDD_PATH" --size $((DISK_GB*1024)) --format VDI --variant Standard
VBoxManage storageattach "$NAME" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "$HDD_PATH" --discard on --nonrotational on

# 5. ISO
VBoxManage storageattach "$NAME" --storagectl "IDE"  --port 0 --device 0 --type dvddrive --medium "$ISO"

# 6. Start (headless)
VBoxManage startvm "$NAME" --type headless
```

## 3. Install Guest Additions

After the OS install finishes:

**Linux:**

```bash
# Inside the guest
sudo apt install -y build-essential dkms linux-headers-$(uname -r)

# In VBox GUI: Devices -> Insert Guest Additions CD image...
sudo mount /dev/cdrom /mnt
sudo /mnt/VBoxLinuxAdditions.run
sudo reboot
```

**Windows:**

- Devices -> Insert Guest Additions CD image -> run `VBoxWindowsAdditions.exe` -> reboot.

Verify:

```bash
lsmod | grep vboxguest    # Linux
# Windows: services.msc -> "VirtualBox Guest Additions Service" Running
```

## 4. Post-Install Tweaks

```bash
# Detach the install ISO
VBoxManage storageattach "$NAME" --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium none

# Set boot order to disk-only
VBoxManage modifyvm "$NAME" --boot1 disk --boot2 none --boot3 none --boot4 none

# Take baseline snapshot
VBoxManage snapshot "$NAME" take "clean-baseline" --description "Fresh install $(date -I)"
```

## 5. Linked Clones for Throwaway VMs

```bash
# 1. Generalize the parent, then take a snapshot
VBoxManage snapshot "$NAME" take "golden"

# 2. Linked clone (delta disk only)
VBoxManage clonevm "$NAME" \
  --name "${NAME}-test-01" \
  --options link \
  --snapshot "golden" \
  --register
```

Linked clones boot in seconds and use ~MB instead of ~GB on disk.

## 6. Export / Import for Sharing

```bash
# Export to OVA (portable across VBox/VMware/Hyper-V via OVF)
VBoxManage export "$NAME" -o "${NAME}.ova" \
  --manifest --options manifest,iso \
  --vsys 0 --product "Lab Ubuntu Server" --vendor "Lab" --version "1.0"

# Import elsewhere
VBoxManage import "${NAME}.ova" --vsys 0 --vmname "${NAME}-imported"
```

## 7. Headless Operations

```bash
VBoxHeadless --startvm "$NAME" --vrde on &           # console via RDP on default port 3389
VBoxManage controlvm "$NAME" vrdeport 5000           # change RDP port
VBoxManage controlvm "$NAME" savestate               # equivalent of suspend-to-disk
VBoxManage controlvm "$NAME" acpipowerbutton         # graceful shutdown
```
