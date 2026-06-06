# `lab.yaml` Schema

`lab.yaml` is the declarative inventory of every VM in the lab. The
`make` runners consume it to plan and apply changes.

## Top-Level Keys

| Key | Required | Description |
|-----|----------|-------------|
| `lab` | yes | Metadata about the lab (name, version, DNS, NTP). |
| `hypervisors` | yes | Connection info for each hypervisor the runners can target. |
| `networks` | yes | Named network segments. VMs reference these by name. |
| `vms` | yes | List of VM definitions. |

## `lab` Block

```yaml
lab:
  name: homelab            # human-readable, used in log prefixes
  version: "1.0"           # schema version of this file (not the lab)
  timezone: UTC            # applied during VM post-install
  dns_search: lab.local
  dns_servers: [10.10.20.10, 1.1.1.1]
  ntp_servers: [10.10.20.10, pool.ntp.org]
```

## `hypervisors` Block

```yaml
hypervisors:
  pve01:
    type: proxmox                       # currently: proxmox | hyperv
    host: 10.10.10.11
    ssh_user: root
    ssh_key: ~/.ssh/id_ed25519
    default_bridge: vmbr0
    default_storage: local-lvm
    iso_storage: local
  hyperv01:
    type: hyperv
    host: 10.10.10.12
    win_user: Administrator
    default_switch: vSwitch-Internal
    default_vm_path: "D:\\VMs"
    default_vhd_path: "D:\\VMs\\Virtual Hard Disks"
```

## `networks` Block

```yaml
networks:
  servers:
    vlan_id: 20           # 0 = untagged
    subnet: 10.10.20.0/24
    gateway: 10.10.20.1
    dhcp: false
```

The runner maps the `vlan_id` to the hypervisor-specific tagging command:
- **Proxmox**: `qm set <vmid> --net0 virtio,bridge=vmbr0,tag=<vlan_id>`
- **Hyper-V**: `Set-VMNetworkAdapterVlan -VMName <name> -Access -VlanId <vlan_id>`

## `vms` Block (List)

Each entry describes one VM. Required and optional keys:

| Key | Required | Notes |
|-----|----------|-------|
| `name` | yes | Unique across the lab. Used as the VM identifier on Hyper-V and as the Proxmox VM name. |
| `hypervisor` | yes | Key in the `hypervisors` block. |
| `vmid` | Proxmox only | Numeric ID. |
| `role` | yes | Free-form: `domain_controller`, `web`, `firewall`, etc. |
| `network` | yes | Key in the `networks` block. |
| `secondary_networks` | optional | List of network keys for multi-NIC VMs (e.g. pfSense). |
| `cpu` | yes | vCPU count. |
| `memory_mb` | yes | Startup RAM in MB. |
| `disk_gb` | yes | Boot disk size in GB. |
| `iso` | optional | Installer ISO name (must already be uploaded to the hypervisor). |
| `ip` | optional | Static IP with prefix. If omitted, VM uses DHCP. |
| `start_order` | yes | Lower boots first. Used by `make start` and `make stop`. |
| `onboot` | optional | Hypervisor auto-start. Default: false. |
| `post_install` | optional | Script name to run inside the guest after first boot. |
| `domain` | optional | Domain name to promote (for DCs) or join. |
| `domain_member` | optional | Domain name to join (for member servers). |
| `notes` | optional | Free-form text. Appears in `make plan` output. |

## Validation Rules (enforced by `make validate`)

- Every `vms[].hypervisor` must exist in `hypervisors`.
- Every `vms[].network` and `vms[].secondary_networks[]` must exist in `networks`.
- Proxmox VMs (`hypervisor` of type `proxmox`) must have a numeric `vmid`.
- `vmid` must be unique across the whole lab (PVE requires global uniqueness).
- `name` must be unique across the whole lab.
- `start_order` must be an integer 1-999.
- `cpu` >= 1, `memory_mb` >= 256, `disk_gb` >= 10.

## Future Extensions

These are intentionally not in v1.0 but are queued:

- `vms[].tags` - free-form key/value tags (used for filtering in `make` targets)
- `vms[].data_disks[]` - additional vHDX/qcow2 attachments
- `vms[].backup_schedule` - per-VM retention override
- `cluster` block - Proxmox cluster + shared storage definition
