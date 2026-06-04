# VLAN Configuration

The lab uses 802.1Q VLAN tagging end-to-end: physical switch trunks, hypervisor bridges, and selected guest OSes.

## VLAN Plan (reminder)

| VLAN | Purpose | Subnet | DHCP |
|------|---------|--------|------|
| 10 | Management | 10.10.10.0/24 | none |
| 20 | Servers | 10.10.20.0/24 | reservations |
| 30 | Clients | 10.10.30.0/24 | 100-250 |
| 40 | DMZ | 10.10.40.0/24 | none |
| 99 | Storage | 10.10.99.0/24 | none |

## Physical Switch (TP-Link TL-SG108E example)

1. 802.1Q VLAN -> set port roles:
   - Port 1 -> trunk to pfSense WAN/LAN (untagged on PVID, tagged 10,20,30,40,99)
   - Port 2 -> trunk to Proxmox host (tagged all VLANs, PVID 10)
   - Port 3 -> trunk to Hyper-V host (tagged all VLANs, PVID 10)
   - Port 4 -> access port VLAN 30 to a client laptop
2. PVID matches the management VLAN of each host.
3. Save + apply.

## Hyper-V VLAN

### Per-VM access port

```powershell
Set-VMNetworkAdapterVlan -VMName web01 -Access -VlanId 20
```

### Trunk mode (VM does its own VLAN sub-interfaces)

```powershell
Set-VMNetworkAdapterVlan -VMName pfSense `
                         -Trunk -AllowedVlanIdList 10,20,30,40,99 `
                         -NativeVlanId 0
```

### Verify

```powershell
Get-VMNetworkAdapterVlan -VMName *
```

## Proxmox VLAN

### Bridge-level VLAN awareness

`/etc/network/interfaces` line on the bridge:

```conf
bridge-vlan-aware yes
bridge-vids 2-4094
```

### Per-VM access VLAN

```bash
qm set 101 --net0 virtio,bridge=vmbr0,tag=20
```

### Per-VM trunk (for a router VM like pfSense)

```bash
qm set 200 --net0 virtio,bridge=vmbr0,trunks=10;20;30;40;99
```

Inside pfSense (or any guest), configure sub-interfaces per VLAN ID.

### Linux guest VLAN sub-interface (manual trunk)

`/etc/netplan/01-vlans.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: no
  vlans:
    ens18.10:
      id: 10
      link: ens18
      addresses: [10.10.10.50/24]
    ens18.20:
      id: 20
      link: ens18
      addresses: [10.10.20.50/24]
      routes:
        - to: default
          via: 10.10.20.1
      nameservers:
        addresses: [10.10.20.10]
```

## VMware Workstation VLAN

Workstation does **not** tag VLAN frames at the vSwitch. Two workable approaches:

1. **Inside the guest**: enable 802.1Q on the guest NIC, bridge VMnet0 to a trunked switch port. The OS sends/receives tagged frames.
2. **Per-VLAN VMnets**: bridge VMnet0 to a physical NIC sitting on an access port for VLAN 10, VMnet2 to a NIC on VLAN 20, etc. Coarse but works for desktop labs.

Linux guest with tagged frames (Workstation host on a trunk):

```bash
sudo modprobe 8021q
sudo ip link add link ens33 name ens33.20 type vlan id 20
sudo ip addr add 10.10.20.50/24 dev ens33.20
sudo ip link set ens33.20 up
```

## VirtualBox VLAN

VirtualBox virtual NICs are untagged. Same patterns as Workstation:

- Use bridged adapter to a trunked physical port and tag inside the guest, **or**
- Use a separate Internal Network per VLAN and route via pfSense or a Linux router VM.

## Validation Checklist

| Test | Expected |
|------|----------|
| `ip -d link show ens18.20` (Linux guest) | `vlan protocol 802.1Q id 20` |
| `ping -c1 10.10.20.1` from VLAN 20 client | success |
| `ping -c1 10.10.10.1` from VLAN 20 client | fail unless allowed by firewall |
| `tcpdump -i ens18 -nn vlan` (Linux router) | tagged frames present |
| `ipconfig /all` (Windows guest on access VLAN) | only one IP, no `.20`-style sub-interface needed |
