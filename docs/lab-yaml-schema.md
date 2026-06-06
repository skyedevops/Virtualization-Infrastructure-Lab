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
| `storage` | optional (v2.0) | Proxmox storage to put the boot disk on. Defaults to the hypervisor's `default_storage`. Use `ceph-rbd` for replicated cluster storage or `nfs-vm` for NAS-backed. |
| `ha` | optional (v2.0) | Set to `true` to make `labctl apply` also call `ha-manager add` for this VM. Requires the hypervisor to be in a Proxmox cluster. |
| `ha_group` | optional (v2.0) | Name of the `ha-group` to bind the VM to. Defaults to `default` if `ha: true` is set. |

## `clusters` Block (v2.0)

A Proxmox cluster is a group of nodes that share quorum and (in
this lab's case) share Ceph storage.  The `clusters` block groups
hypervisors and declares shared resources that `labctl.py` can
target without needing to know the per-host internals.

```yaml
clusters:
  prod:
    type: proxmox
    hypervisors: [pve01, pve02, pve03]   # keys from the hypervisors block
    storage:
      - id: ceph-rbd                     # logical name; must match vms[].storage
        type: rbd
        pool: vm-disks
        content: images,rootdir
      - id: nfs-vm
        type: nfs
        server: 10.10.20.5
        export: /volume1/vm
        content: images,rootdir
      - id: nfs-iso
        type: nfs
        server: 10.10.20.5
        export: /volume1/iso
        content: iso,vztmpl
      - id: nfs-backup
        type: nfs
        server: 10.10.20.5
        export: /volume1/backup
        content: backup
    ha_groups:
      default:
        nodes: [pve01, pve02, pve03]      # round-robin failover
        restricted: false                # if true, VMs only land on these nodes
        nofailback: false
```

`labctl.py` resolves a VM's `storage` field against this list to
pick the right `qm create` flag (e.g. `--scsi0 ceph-rbd:20` vs
`--scsi0 nfs-vm:20`).  See
[docs/cluster-storage-decision.md](cluster-storage-decision.md) for
the design rationale.

## Validation Rules (enforced by `make validate`)

- Every `vms[].hypervisor` must exist in `hypervisors`.
- Every `vms[].network` and `vms[].secondary_networks[]` must exist in `networks`.
- Proxmox VMs (`hypervisor` of type `proxmox`) must have a numeric `vmid`.
- `vmid` must be unique across the whole lab (PVE requires global uniqueness).
- `name` must be unique across the whole lab.
- `start_order` must be an integer 1-999.
- `cpu` >= 1, `memory_mb` >= 256, `disk_gb` >= 10.
- v2.0: every cluster in `clusters` must reference existing
  hypervisors; every `vms[].storage` (if set) must exist in the
  storage list of the cluster the VM's hypervisor belongs to;
  every `vms[].ha_group` (if set) must exist in the cluster's
  `ha_groups`.
- v2.0: a VM with `ha: true` must live on a hypervisor that
  belongs to a Proxmox cluster.

## Future Extensions

These are intentionally not in v2.0 but are queued:

- `vms[].tags` - free-form key/value tags (used for filtering in `make` targets)
- `vms[].data_disks[]` - additional vHDX/qcow2 attachments
- `vms[].backup_schedule` - per-VM retention override
