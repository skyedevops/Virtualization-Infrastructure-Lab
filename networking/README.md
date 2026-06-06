# Virtual Networking

Networking is the most-overlooked tier of a virtualization lab. This section catalogs every virtual switch/bridge type used in the lab, the per-hypervisor implementation, VLAN strategy, and pfSense as the lab's edge firewall.

## Contents

- [virtual-switches.md](virtual-switches.md) - vSwitch / vBridge concepts and per-hypervisor cheat sheets
- [vlan-configuration.md](vlan-configuration.md) - 802.1Q VLAN tagging, trunks, and access ports
- [pfsense-setup.md](pfsense-setup.md) - pfSense as the lab edge firewall + router

## Virtual Switch Concept Map

| Concept | VMware | Hyper-V | Proxmox/KVM | VirtualBox |
|---------|--------|---------|-------------|------------|
| Bridged-to-LAN | VMnet0 (Bridged) | vSwitch (External) | Linux bridge (`vmbr0`) on physical NIC | Bridged Adapter |
| Host-only | VMnet1+ (Host-only) | vSwitch (Internal) | Linux bridge with no `bridge-ports` | Host-only Adapter |
| VM-only / isolated | Custom VMnet | vSwitch (Private) | bridge with no NIC + isolated VMs | Internal Network |
| NAT | VMnet8 (NAT) | NAT vSwitch (Windows 10 only) | `vmbr0` + iptables MASQUERADE | NAT / NAT Network |
| 802.1Q tagged | guest-side only | vSwitch w/ VLAN-aware NIC | `bridge-vlan-aware yes` + `tag=` | Wire VLAN inside guest |

## Lab-Wide IPAM

| VLAN | Subnet | Gateway | DHCP | Notes |
|------|--------|---------|------|-------|
| 10 MGMT | 10.10.10.0/24 | 10.10.10.1 (pfSense) | static only | Hypervisor mgmt IPs |
| 20 SERVERS | 10.10.20.0/24 | 10.10.20.1 | reservations only | AD/DNS/DHCP/app servers |
| 30 CLIENTS | 10.10.30.0/24 | 10.10.30.1 | 100-250 | Win10/11 + Linux desktops |
| 40 DMZ | 10.10.40.0/24 | 10.10.40.1 | static only | Reverse proxy + web |
| 99 STORAGE | 10.10.99.0/24 | 10.10.99.1 | static only | NAS, backup target, no internet egress |

## Inter-VLAN Routing & Firewall Rules

pfSense routes between all VLANs with the following baseline rules:

| Rule | From | To | Service | Action |
|------|------|----|---------|--------|
| Admin-from-MGMT | 10.10.10.0/24 | any | any | allow |
| Servers-to-internet | 10.10.20.0/24 | WAN | TCP/80,443 + DNS | allow |
| Clients-to-Servers | 10.10.30.0/24 | 10.10.20.0/24 | RDP, SMB, AD, DNS | allow |
| Clients-to-DMZ | 10.10.30.0/24 | 10.10.40.0/24 | HTTP/HTTPS | allow |
| DMZ-to-anywhere | 10.10.40.0/24 | RFC1918 | any | **deny** |
| Storage isolation | 10.10.99.0/24 | !10.10.99.0/24 | any | deny |
| Default | any | any | any | deny + log |

## Quick Sanity Tests

After bringing up a new VM:

```bash
# IP and route
ip -br a
ip r

# DNS
resolvectl status        # systemd-resolved
nslookup dc01.lab.local

# Gateway reachable
ping -c 3 10.10.20.1

# Cross-VLAN
ping -c 3 10.10.30.1     # clients gw
ping -c 3 1.1.1.1        # internet

# Port reachability
nc -zv dc01.lab.local 389
```text

PowerShell equivalents:

```powershell
Test-NetConnection -ComputerName dc01.lab.local -Port 389
Test-NetConnection -ComputerName 1.1.1.1 -Port 443
Get-NetIPConfiguration
Get-DnsClientServerAddress
```text
