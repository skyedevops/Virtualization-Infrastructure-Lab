# Physical Topology

How every box, cable, and NIC in the lab is wired together.

```mermaid
flowchart TB
    Internet([Internet / WAN])
    Router[Home Router<br/>192.168.1.1/24]
    Pfsense[pfSense VM<br/>on Proxmox<br/>WAN: DHCP<br/>LAN: 10.10.0.1]
    Switch[Managed Switch<br/>8-port 1GbE<br/>802.1Q trunk]

    Hyperv[Hyper-V Host<br/>Win Srv 2022<br/>enp1s0]
    Proxmox[Proxmox Node<br/>Debian 12<br/>enp1s0]
    Workstation[Workstation<br/>Win 11<br/>vmnet0 bridged]
    NAS[NAS<br/>10.10.99.20<br/>NFS + SMB]
    Admin([Admin Laptop])

    Internet --> Router
    Router -- WAN DHCP --> Pfsense
    Pfsense -- Trunk VLAN 10,20,30,40,99 --> Switch

    Switch -- PVID 10 untagged + tagged 20,30,40,99 --> Hyperv
    Switch -- PVID 10 untagged + tagged 20,30,40,99 --> Proxmox
    Switch -- PVID 10 untagged + tagged 20,30,40,99 --> Workstation
    Switch -- PVID 99 untagged --> NAS
    Switch -- PVID 30 access --> Admin

    classDef physical fill:#e3f2fd,stroke:#1565c0,color:#000
    classDef mgmt fill:#e8f5e9,stroke:#2e7d32,color:#000
    classDef vm fill:#fff3e0,stroke:#ef6c00,color:#000
    classDef backup fill:#ffebee,stroke:#c62828,color:#000

    class Internet,Router,Switch physical
    class Pfsense,Hyperv,Proxmox,Workstation mgmt
    class Admin vm
    class NAS backup
```

## Notes

- The switch port to each hypervisor is an **802.1Q trunk** carrying
  all five VLANs. The PVID (untagged) is always the management VLAN
  (10) so the hypervisor's mgmt IP works without a tagged frame.
- The NAS is on a **dedicated access port** in VLAN 99 (Storage).
  It can talk to the rest of the lab but nothing talks *out* of it
  via VLAN 99.
- The admin laptop plugs into a **VLAN 30 access port** for normal
  client work. To reach the hypervisor mgmt plane, the laptop joins
  VLAN 10 (or routes through pfSense if policy allows).
- pfSense is the only host with one foot in the WAN (via the home
  router) and one foot in the lab trunk. If pfSense is down, VMs
  can still talk to each other on the same VLAN but cannot reach
  other VLANs or the internet.
