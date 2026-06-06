# Virtual Switches - Per-Hypervisor Reference

Cheat sheet for creating and inspecting virtual switches/bridges in each hypervisor.

## VMware Workstation

### Inspect

```powershell
# Windows PowerShell
Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "*VMware*"}
```text

GUI: **Edit -> Virtual Network Editor** (must run as Administrator).

### Create custom host-only network

1. Add Network -> select an unused VMnet (e.g. VMnet2).
2. Type: Host-only.
3. Subnet: `10.10.20.0/24`.
4. DHCP: enable, range `.100-.200`.

CLI (Linux host):

```bash
sudo vmware-netcfg
```text

### Attach VM to a switch

`.vmx` snippet:

```text
ethernet0.present = "TRUE"
ethernet0.connectionType = "custom"
ethernet0.vnet = "VMnet2"
ethernet0.virtualDev = "vmxnet3"
ethernet0.addressType = "generated"
```text

---

## Hyper-V

### Create / inspect

```powershell
# Existing switches
Get-VMSwitch | Format-Table Name, SwitchType, NetAdapterInterfaceDescription

# External - bound to physical NIC
New-VMSwitch -Name "vSwitch-External" `
             -NetAdapterName "Ethernet" -AllowManagementOS $true

# Internal - host can talk to VMs
New-VMSwitch -Name "vSwitch-Internal" -SwitchType Internal

# Private - VM-to-VM only on this host
New-VMSwitch -Name "vSwitch-Private" -SwitchType Private
```text

### Attach a VM NIC

```powershell
Add-VMNetworkAdapter -VMName web01 -SwitchName vSwitch-External -Name "lan"

# Set MAC, VLAN, bandwidth
Set-VMNetworkAdapter -VMName web01 -Name lan -StaticMacAddress 00155D010203
Set-VMNetworkAdapterVlan  -VMName web01 -Access -VlanId 20
Set-VMNetworkAdapter -VMName web01 -Name lan `
                     -MinimumBandwidthAbsolute 10MB `
                     -MaximumBandwidth        100MB
```text

### Allow MAC spoofing (needed for nested labs)

```powershell
Set-VMNetworkAdapter -VMName nested-pve -MacAddressSpoofing On
```text

---

## Proxmox VE (Linux bridges)

### Inspect

```bash
ip -br link show type bridge
brctl show              # legacy but informative
cat /etc/network/interfaces
```text

### Add a VLAN-aware bridge (in `/etc/network/interfaces`)

```conf
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```text

Apply: `ifreload -a` (needs `apt install ifupdown2`).

### Add a NIC to a VM with VLAN tag

```bash
qm set 101 --net1 virtio,bridge=vmbr0,tag=20
```text

### Linux bond + bridge example (LACP)

```conf
auto bond0
iface bond0 inet manual
    bond-slaves enp1s0 enp2s0
    bond-miimon 100
    bond-mode 802.3ad
    bond-xmit-hash-policy layer3+4

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.11/24
    gateway 10.10.10.1
    bridge-ports bond0
    bridge-vlan-aware yes
```text

### OVS bridge (alternative)

```bash
apt install openvswitch-switch
# in /etc/network/interfaces:
auto vmbr0
iface vmbr0 inet manual
    ovs_type OVSBridge
    ovs_ports enp1s0
```text

---

## VirtualBox

### Inspect

```bash
VBoxManage list hostonlyifs
VBoxManage list natnetworks
VBoxManage list bridgedifs
VBoxManage list intnets
```text

### Create a NAT Network

```bash
VBoxManage natnetwork add --netname LabNet --network "10.10.50.0/24" --dhcp on
VBoxManage natnetwork start --netname LabNet
```text

### Create a host-only adapter with an IP

```bash
VBoxManage hostonlyif create
VBoxManage hostonlyif ipconfig vboxnet1 --ip 192.168.57.1 --netmask 255.255.255.0
```text

### Attach NICs to a VM

```bash
VBoxManage modifyvm "ubuntu-01" \
  --nic1 natnetwork --nat-network1 LabNet --nictype1 virtio \
  --nic2 hostonly --hostonlyadapter2 vboxnet0 --nictype2 virtio \
  --nic3 intnet   --intnet3 "isolated-test" --nictype3 virtio
```text

### Port forward (NAT mode only, single VM)

```bash
VBoxManage modifyvm "ubuntu-01" \
  --natpf1 "ssh,tcp,,2222,,22" \
  --natpf1 "http,tcp,,8080,,80"
```text

---

## Decision Matrix

| Need | VMware | Hyper-V | Proxmox | VirtualBox |
|------|--------|---------|---------|------------|
| VM on the LAN | Bridged (VMnet0) | External | Linux bridge on physical NIC | Bridged Adapter |
| Internet via host NAT | NAT (VMnet8) | NAT (Win10+ only) | iptables MASQUERADE or via pfSense VM | NAT or NAT Network |
| Host <-> VM only | Host-only (VMnet1) | Internal | bridge without phys NIC | Host-only |
| Strict VM-to-VM | Custom VMnet host-only | Private | bridge with no NIC, no host vNIC | Internal Network |
| Tagged VLANs from vSwitch | guest-side (inside VM) | yes (per-NIC) | yes (`bridge-vlan-aware` + `tag=`) | guest-side only |
| Bond / LACP uplink | manual | NIC Teaming (LBFO) | Linux bonding | not native |
