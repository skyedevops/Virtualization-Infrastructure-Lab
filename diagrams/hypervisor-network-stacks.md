# Hypervisor Network Stack Comparison

How each hypervisor models a virtual network, side by side.

## Layered Model

```mermaid
flowchart TB
    subgraph Guest["GUEST VM"]
        eth0["eth0 (guest OS)"]
    end

    subgraph Hypervisor["HYPERVISOR ABSTRACTION LAYER"]
        direction LR
        subgraph Vmware["VMware Workstation"]
            vnet["VMnet<br/>(named vSwitch)"]
        end
        subgraph Hyperv["Hyper-V"]
            vswitch["vSwitch<br/>(External/Internal/Private)"]
        end
        subgraph Pve["Proxmox VE / KVM"]
            vbr["vmbr0<br/>(Linux bridge, VLAN-aware)"]
        end
        subgraph Vbox["VirtualBox"]
            vbif["NIC mode<br/>(Bridged/NAT/Host-only/Internal)"]
        end
    end

    subgraph Host["HOST PHYSICAL NIC"]
        nic["enp1s0 / Ethernet"]
    end

    eth0 --> vnet
    eth0 --> vswitch
    eth0 --> vbr
    eth0 --> vbif

    vnet --> nic
    vswitch --> nic
    vbr --> nic
    vbif --> nic
```

## Concept-to-Command Map

```mermaid
flowchart LR
    subgraph Need["What you need"]
        N1["VM on the LAN"]
        N2["Internet via host NAT"]
        N3["Host &lt;-&gt; VM only"]
        N4["Strict VM-to-VM isolated"]
        N5["802.1Q tagged VLAN at vSwitch"]
    end

    subgraph Vmware["VMware"]
        V1["Bridged (VMnet0)"]
        V2["NAT (VMnet8)"]
        V3["Host-only (VMnet1)"]
        V4["Custom VMnet host-only"]
        V5["Tag inside guest"]
    end

    subgraph Hyperv["Hyper-V"]
        H1["vSwitch External"]
        H2["vSwitch NAT (Win10+)"]
        H3["vSwitch Internal"]
        H4["vSwitch Private"]
        H5["Set-VMNetworkAdapterVlan<br/>-Access -VlanId 20"]
    end

    subgraph Pve["Proxmox"]
        P1["vmbr0 + physical NIC"]
        P2["iptables MASQUERADE<br/>or via pfSense VM"]
        P3["bridge-ports none"]
        P4["bridge-ports none<br/>+ no host vNIC"]
        P5["bridge-vlan-aware yes<br/>+ tag=20 on NIC"]
    end

    subgraph Vbox["VirtualBox"]
        B1["Bridged Adapter"]
        B2["NAT or NAT Network"]
        B3["Host-only Adapter"]
        B4["Internal Network"]
        B5["Tag inside guest"]
    end

    N1 --- V1 & H1 & P1 & B1
    N2 --- V2 & H2 & P2 & B2
    N3 --- V3 & H3 & P3 & B3
    N4 --- V4 & H4 & P4 & B4
    N5 --- V5 & H5 & P5 & B5
```

## Key Takeaways

- **Proxmox wins for VLAN density** - one bridge, 4094 VLANs, no
  per-VM switch. The other three either require per-NIC VLAN config
  (Hyper-V) or punt VLAN tagging entirely to the guest (VMware,
  VirtualBox).
- **VMware wins for ergonomics** - VMnet0/1/8 defaults cover 80% of
  needs, the GUI makes the rest obvious, and `vmrun` is the only
  CLI that handles snapshots, power, and guest exec in one tool.
- **Hyper-V wins for Windows integration** - vSwitch binds to the
  Hyper-V virtual NIC stack, and PowerShell gives full access. The
  trade-off is that there's no equivalent of `vmrun guest exec` -
  you push commands via WinRM/PowerShell Direct instead.
- **VirtualBox wins for cross-platform portability** - same `.vbox`
  file works on Windows, Linux, macOS. That's why Vagrant defaults
  to it. The trade-off is no over-commit, so RAM ceiling = sum of
  fixed allocations.
