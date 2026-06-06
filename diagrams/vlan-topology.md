# VLAN / Logical Topology

The five routed segments. All routing happens in pfSense.

```mermaid
flowchart LR
    subgraph VLAN10["VLAN 10 - MGMT  10.10.10.0/24"]
        direction TB
        Pve([pve01<br/>10.10.10.11])
        Hyperv([hyperv01<br/>10.10.10.12])
        Wkstn([wkstn01<br/>10.10.10.13])
        Pfsense10([pfSense MGMT<br/>10.10.10.1])
    end

    subgraph VLAN20["VLAN 20 - SERVERS  10.10.20.0/24"]
        direction TB
        DC([dc01<br/>10.10.20.10])
        FS([fs01<br/>10.10.20.20])
        Grafana([grafana<br/>10.10.20.50])
        Pfsense20([pfSense GW<br/>10.10.20.1])
    end

    subgraph VLAN30["VLAN 30 - CLIENTS  10.10.30.0/24"]
        direction TB
        WinA([win10-a<br/>DHCP .100-250])
        LinA([ubuntu-desktop<br/>DHCP])
        Pfsense30([pfSense GW<br/>10.10.30.1])
    end

    subgraph VLAN40["VLAN 40 - DMZ  10.10.40.0/24"]
        direction TB
        Web([web01<br/>10.10.40.10])
        RP([nginx-rp<br/>10.10.40.5])
        Pfsense40([pfSense GW<br/>10.10.40.1])
    end

    subgraph VLAN99["VLAN 99 - STORAGE  10.10.99.0/24"]
        direction TB
        NAS([nas01<br/>10.10.99.20])
        PBS([pbs01<br/>10.10.99.10])
        Pfsense99([pfSense GW<br/>10.10.99.1])
    end

    Pfsense10 <--> Pfsense20
    Pfsense20 <--> Pfsense30
    Pfsense20 <--> Pfsense40
    Pfsense20 <--> Pfsense99

    Web --> RP
    FS --> DC

    classDef mgmt fill:#e8f5e9,stroke:#2e7d32
    classDef server fill:#e3f2fd,stroke:#1565c0
    classDef client fill:#fff8e1,stroke:#f9a825
    classDef dmz fill:#ffebee,stroke:#c62828
    classDef storage fill:#f3e5f5,stroke:#6a1b9a

    class Pve,Hyperv,Wkstn,Pfsense10 mgmt
    class DC,FS,Grafana,Pfsense20 server
    class WinA,LinA,Pfsense30 client
    class Web,RP,Pfsense40 dmz
    class NAS,PBS,Pfsense99 storage
```text

## Routing & Firewall Summary

| From | To | Default | Notes |
|------|----|---------|-------|
| VLAN 10 (MGMT) | Any | **Allow** | Admin only - trusted |
| VLAN 20 (SERVERS) | WAN | **Allow** 80/443 + DNS | Web egress for updates |
| VLAN 20 | VLAN 30/40/99 | **Allow** specific (RDP, SMB, AD, NFS) | Server-to-client controlled |
| VLAN 30 (CLIENTS) | VLAN 20 | **Allow** RDP, SMB, AD DNS, LDAP | Standard workstation traffic |
| VLAN 30 | VLAN 40 (DMZ) | **Allow** 80/443 | Web browsing |
| VLAN 30 | WAN | **Allow** 80/443 + DNS | Normal client internet |
| VLAN 40 (DMZ) | Any RFC1918 | **DENY** | DMZ must not touch internal |
| VLAN 40 | WAN | **Allow** 80/443 only | For package mirrors + cert renewal |
| VLAN 99 (STORAGE) | !VLAN 99 | **DENY** | Storage island, no internet, no LAN egress by default |
| Any | Any | **Deny + log** | Last rule |

## Why This Shape

- **VLAN 10 is the smallest** - only the three management IPs. Hard
  to fat-finger because there's no DHCP and no other endpoints.
- **VLAN 99 is a true island** - one firewall rule and you've cut off
  the backup target from the rest of the lab, which is exactly what
  you want when ransomware starts walking the network.
- **DMZ is between two denies** - DMZ to RFC1918 blocked, WAN to DMZ
  unfiltered. This is the "sacrificial layer" pattern. The web
  server gets popped, the attacker is contained, internal LAN is
  intact.
