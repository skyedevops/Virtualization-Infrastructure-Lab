# VMware Workstation - Networking

VMware Workstation provides three default virtual networks plus the ability to define up to 20 custom networks (VMnet0-VMnet19). The Virtual Network Editor (Windows: Edit -> Virtual Network Editor; must run as Administrator) is the GUI; `vnetlib` and `vmware-netcfg` are the CLI equivalents.

## Default Networks

| VMnet | Type | Default Subnet | Purpose |
|-------|------|----------------|---------|
| VMnet0 | Bridged | matches physical NIC | VM appears on the physical LAN |
| VMnet1 | Host-only | 192.168.79.0/24 | Isolated from physical LAN, host can talk to VMs |
| VMnet8 | NAT | 192.168.40.0/24 | VMs get outbound internet via host NAT |

## Network Mode Cheat Sheet

| Need | Use |
|------|-----|
| VM gets a LAN IP from your physical router | Bridged (VMnet0) |
| VM needs internet but should not be reachable from LAN | NAT (VMnet8) |
| VM must only talk to the host and other VMs on the same VMnet | Host-only (VMnet1) |
| Multi-tier app sim (web/app/db) on separate segments | Custom host-only VMnets |
| VLAN tagging from inside the VM | Bridged + 802.1Q in guest |

## Adding a Custom Host-Only Network

In the Virtual Network Editor:

1. **Add Network** -> select `VMnet2`
2. Type: **Host-only**
3. Subnet IP: `10.10.20.0`, mask `255.255.255.0`
4. DHCP: enable, range `10.10.20.100 - 10.10.20.200`, lease 30 min
5. Apply.

Verify on Windows host:

```powershell
Get-NetAdapter | Where-Object {$_.Name -like "*VMnet*"}
ipconfig | findstr /C:"VMware Network Adapter"
```text

You should see a `VMware Network Adapter VMnet2` interface with IP `10.10.20.1`.

## Bridging to a Specific Physical NIC

By default VMnet0 auto-bridges to the "best" host NIC. To pin it:

1. Virtual Network Editor -> VMnet0 -> Bridged to: select the exact adapter (e.g., `Intel(R) Ethernet I225-V`).
2. **Automatic Settings...** -> uncheck all NICs except the chosen one.

## VLAN Tagging

VMware Workstation does **not** apply VLAN tags at the vSwitch level (that's an ESXi/Hyper-V feature). Two options:

1. **VLAN tagging inside the guest** - configure 802.1Q sub-interfaces in the guest OS, then bridge to a trunked switch port.
2. **Trunk multiple bridged networks** - bridge VMnet0 to a NIC on an access port for VLAN 10, VMnet2 to a NIC on VLAN 20, etc.

Linux guest VLAN sub-interface example:

```bash
sudo ip link add link ens33 name ens33.20 type vlan id 20
sudo ip addr add 10.10.20.50/24 dev ens33.20
sudo ip link set ens33.20 up
```text

Persist via `/etc/netplan/01-netcfg.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: no
  vlans:
    ens33.20:
      id: 20
      link: ens33
      addresses: [10.10.20.50/24]
      gateway4: 10.10.20.1
      nameservers:
        addresses: [10.10.20.10]
```text

## NAT Port Forwarding (VMnet8)

To expose a service on a NAT'd VM to the host's LAN:

1. Virtual Network Editor -> VMnet8 -> NAT Settings...
2. **Add** port forward:
   - Host port: `8080`
   - Type: TCP
   - VM IP: `192.168.40.130`
   - VM port: `80`
   - Description: `web01 HTTP`
3. OK -> Apply.

Test from another host on the LAN: `curl http://<host-ip>:8080/`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bridged VM has no IP | Re-run **Restore Defaults** in Virtual Network Editor; verify host NIC is up |
| Host-only VM cannot reach host | Check Windows Firewall; allow on "VMware Network Adapter VMnetX" |
| NAT VM slow DNS | Set explicit DNS (1.1.1.1) in guest; default gateway is `<subnet>.2` |
| "Device VMnet0 is not running" | Run `net start VMnetBridge` or repair install of Workstation |
