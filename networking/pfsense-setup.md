# pfSense as Lab Edge Firewall

pfSense (or its fork OPNsense) runs as a VM and provides:

- WAN/LAN routing for the lab
- Inter-VLAN routing + firewall
- DHCP server (per VLAN)
- DNS resolver (Unbound)
- VPN (OpenVPN / WireGuard) for remote access
- IDS/IPS (Suricata / Snort) on a high-RAM host

## VM Sizing

| Spec | Value |
|------|-------|
| vCPU | 2 |
| RAM | 2 GB (4 GB if running Suricata) |
| Disk | 20 GB |
| NICs | 2+ (WAN, LAN-trunk) |

## 1. Build the VM (Proxmox example)

```bash
qm create 100 --name pfsense --memory 2048 --cores 2 \
  --cpu host --machine q35 --bios ovmf \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0,format=raw \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:20 \
  --net0 virtio,bridge=vmbr0                          # WAN
  --net1 virtio,bridge=vmbr0,trunks=10;20;30;40;99    # LAN trunk

# Mount installer ISO
qm set 100 --ide2 local:iso/pfSense-CE-2.7.2-RELEASE-amd64.iso,media=cdrom
qm set 100 --boot order=ide2
qm start 100
```text

## 2. Initial Console Install

1. Accept license -> Install -> ZFS root mirror if you have two disks, otherwise UFS.
2. Reboot, eject ISO.
3. At the console menu:
   - Option 1: Assign Interfaces -> WAN=vtnet0, LAN=vtnet1, VLANs **yes**:
     - Parent: `vtnet1`, VLAN tags: 10, 20, 30, 40, 99
   - Option 2: Set LAN IP -> `10.10.10.1/24` on `VLAN10` (or whichever you choose for management).

## 3. First Web Login

Browse to `https://10.10.10.1` from a VLAN 10 host.

Default credentials: `admin / pfsense` -> the setup wizard immediately forces a change.

## 4. Wizard Walk-Through

1. Hostname: `pfsense`, Domain: `lab.local`
2. Primary/Secondary DNS: `1.1.1.1`, `1.0.0.1` (override Unbound if you want internal-only)
3. NTP: `pool.ntp.org`
4. WAN: DHCP (typical home setup)
5. LAN IP: `10.10.10.1/24`
6. Change admin password.

## 5. Interfaces

Interfaces -> Assignments -> map each VLAN to a "real" pfSense interface:

| pfSense IF | Parent + VLAN | IP |
|------------|---------------|----|
| LAN  | VLAN 10 on vtnet1 | 10.10.10.1/24 |
| OPT1 | VLAN 20 on vtnet1 | 10.10.20.1/24 |
| OPT2 | VLAN 30 on vtnet1 | 10.10.30.1/24 |
| OPT3 | VLAN 40 on vtnet1 | 10.10.40.1/24 |
| OPT4 | VLAN 99 on vtnet1 | 10.10.99.1/24 |

Enable + name each one (`MGMT`, `SERVERS`, `CLIENTS`, `DMZ`, `STORAGE`).

## 6. DHCP per VLAN

Services -> DHCP Server -> per interface:

| Interface | Range | Gateway | DNS |
|-----------|-------|---------|-----|
| CLIENTS | 10.10.30.100-250 | 10.10.30.1 | 10.10.20.10 |
| SERVERS | reservations only | 10.10.20.1 | 10.10.20.10 |

## 7. Firewall Rules

Apply the matrix from [README.md](README.md). Examples (Firewall -> Rules):

**SERVERS interface:**

| Action | Proto | Source | Dest | Port | Description |
|--------|-------|--------|------|------|-------------|
| Pass | TCP/UDP | SERVERS net | this firewall | 53 | DNS |
| Pass | TCP | SERVERS net | any | 80,443 | Web egress |
| Pass | UDP | SERVERS net | 0.pool.ntp.org | 123 | NTP |
| Block | any | SERVERS net | RFC1918 !SERVERS,STORAGE | any | Inter-VLAN deny by default |

**DMZ interface:**

| Action | Proto | Source | Dest | Port | Description |
|--------|-------|--------|------|------|-------------|
| Block | any | DMZ net | RFC1918 | any | DMZ to internal: deny |
| Pass | TCP | DMZ net | any | 80,443 | Internet egress |

## 8. DNS (Unbound)

Services -> DNS Resolver:

- Enable, listen on all interfaces.
- Domain Overrides: `lab.local` -> `10.10.20.10` (AD DC).
- Host Overrides: pre-populate critical names (`pfsense.lab.local`, `nas.lab.local`).

## 9. Site-to-Lab VPN (WireGuard)

VPN -> WireGuard -> Tunnels -> Add:

- Tunnel address: `10.99.0.1/24`
- Listen port: `51820`
- Peers: one per remote device, with allowed IPs `10.10.0.0/16` and a key pair generated client-side.

Firewall -> Rules -> WAN -> Pass UDP/51820 to This Firewall.

## 10. Backups

Diagnostics -> Backup & Restore -> **schedule** a config backup to:

- The encrypted built-in Auto Config Backup service (free with a pfSense+ account), or
- Local file pulled by your normal backup process from `/cf/conf/config.xml` (use SSH key auth).

## 11. Verification

```bash
# From a VLAN 30 client
ping -c2 10.10.30.1     # local gw OK
ping -c2 10.10.20.10    # AD DNS OK
ping -c2 1.1.1.1        # internet OK
nslookup dc01.lab.local # resolves to 10.10.20.10
traceroute 1.1.1.1      # first hop = pfSense
```text
