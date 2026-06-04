# VirtualBox - Installation

## 1. Pre-flight

- VT-x / AMD-V enabled in BIOS.
- On Windows: Hyper-V / WHP / Windows Sandbox / WSL2 will conflict.
  - Either uninstall those features, or use VirtualBox 6.1.x+ which can co-exist with Hyper-V via WHP at a perf cost.
- On Linux: kernel headers + DKMS for the matching kernel.

## 2. Install

### Windows

1. Download from <https://www.virtualbox.org/wiki/Downloads>.
2. Run installer. Accept the network adapter reset prompt.
3. (Optional) Install **Oracle VM VirtualBox Extension Pack** for USB 2.0/3.0, RDP, PXE-boot for Intel cards, disk encryption.

### macOS

1. Download the `.dmg`.
2. May require granting kernel extension permission in **System Settings -> Privacy & Security**.
3. Reboot if prompted.

### Linux (Debian/Ubuntu)

```bash
sudo apt update
sudo apt install -y linux-headers-$(uname -r) dkms
wget -O- https://www.virtualbox.org/download/oracle_vbox_2016.asc | \
  sudo gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox-2016.gpg

echo "deb [signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] \
http://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" | \
  sudo tee /etc/apt/sources.list.d/virtualbox.list

sudo apt update
sudo apt install -y virtualbox-7.0
sudo usermod -aG vboxusers $USER
newgrp vboxusers
```

### Linux (Fedora/RHEL)

```bash
sudo dnf install -y kernel-devel-$(uname -r) dkms
sudo dnf install -y https://download.virtualbox.org/virtualbox/rpm/el/oracle-virtualbox-2016.repo
sudo dnf install -y VirtualBox-7.0
```

## 3. Extension Pack

```bash
VERSION=$(VBoxManage --version | cut -d'r' -f1)
wget "https://download.virtualbox.org/virtualbox/${VERSION}/Oracle_VM_VirtualBox_Extension_Pack-${VERSION}.vbox-extpack"
sudo VBoxManage extpack install "Oracle_VM_VirtualBox_Extension_Pack-${VERSION}.vbox-extpack"
VBoxManage list extpacks
```

The Extension Pack is licensed under PUEL (free for personal/eval/academic, paid for commercial).

## 4. Default Folders & Preferences

```bash
# Move default machine folder to a faster/larger disk
VBoxManage setproperty machinefolder "$HOME/VirtualBox VMs"

# Or on Windows:
VBoxManage setproperty machinefolder "D:\VBoxVMs"

# Default VRDE library (free; for RDP-style console)
VBoxManage setproperty vrdeauthlibrary default
```

## 5. Networking Defaults

Verify the host-only adapter exists:

```bash
VBoxManage list hostonlyifs
# Expect: vboxnet0 (Linux/macOS) or 'VirtualBox Host-Only Ethernet Adapter' (Windows)
```

If missing, create one:

```bash
VBoxManage hostonlyif create
VBoxManage hostonlyif ipconfig vboxnet0 --ip 192.168.56.1 --netmask 255.255.255.0
```

Create a NAT Network for multi-VM labs that need internet + inter-VM traffic:

```bash
VBoxManage natnetwork add --netname LabNet \
  --network "10.10.50.0/24" --dhcp on --ipv6 off
VBoxManage natnetwork start --netname LabNet
```

## 6. Validation

```bash
VBoxManage --version
VBoxManage list extpacks
VBoxManage list hostonlyifs
VBoxManage list natnetworks
```
