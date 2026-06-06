# Backup Data Flow

Where the bits go from "live VM" to "off-site, encrypted, deduplicated".

```mermaid
flowchart LR
    subgraph Live["LIVE - on the hypervisor host"]
        VM[VM/CT disk<br/>qcow2 / vhdx / vmdk]
        Snap[Snapshot<br/>taken at 02:00]
    end

    subgraph Stage1["TIER 1 - local backup target"]
        Nas[NAS share<br/>NFS or SMB<br/>nightly vzdump]
    end

    subgraph Stage2["TIER 2 - deduplication engine"]
        Pbs[Proxmox Backup Server<br/>4KB dedup<br/>AES-256 encrypted]
    end

    subgraph Stage3["TIER 3 - off-site"]
        Cloud[Backblaze B2<br/>rclone sync nightly<br/>lifecycle 90d -> Glacier]
    end

    subgraph Stage4["TIER 4 - retention"]
        R1[Hourly snapshots<br/>keep 6]
        R2[Daily<br/>keep 7]
        R3[Weekly<br/>keep 4]
        R4[Monthly<br/>keep 6]
    end

    VM -->|qm snapshot /<br/>Checkpoint-VM| Snap
    Snap -->|vzdump --mode snapshot| Nas
    Snap -->|PBS backup| Pbs
    Nas -->|rclone sync| Cloud

    Pbs --> R1
    Pbs --> R2
    Pbs --> R3
    Pbs --> R4

    classDef live fill:#fff3e0,stroke:#ef6c00
    classDef tier1 fill:#e3f2fd,stroke:#1565c0
    classDef tier2 fill:#e8f5e9,stroke:#2e7d32
    classDef tier3 fill:#ffebee,stroke:#c62828
    classDef tier4 fill:#f3e5f5,stroke:#6a1b9a

    class VM,Snap live
    class Nas tier1
    class Pbs tier2
    class Cloud tier3
    class R1,R2,R3,R4 tier4
```

## Three Independent Copy Paths

| Path | Tool | Copies to | Schedule | Encryption |
|------|------|-----------|----------|------------|
| A | `vzdump` to NAS | NAS share | Nightly | At-rest NAS only |
| B | `pvesm backup` to PBS | PBS datastore | Nightly | Client-side AES-256 |
| C | `rclone sync` from NAS | B2 cloud bucket | Nightly | rclone crypt (B2 has SSE) |

If A fails (NAS dead), B is current. If A and B both fail, C is at
most 24 h old (RPO). If C fails, A and B are local. The 3-2-1 rule
is met by the union of these three paths.

## Why Both NAS and PBS?

They look redundant but solve different problems.

- **NAS** is the cheap, slow, full-copy archive. Easy to browse
  (`ls`), easy to restore with stock tools, no special client
  required. Use it for "I deleted the wrong file, give me last
  Tuesday's version" restores.
- **PBS** is the dedup engine. 500 GB of unique blocks in your VMs
  becomes 50 GB of backup storage after dedup. Use it for "the
  hypervisor host died, restore 8 VMs" emergencies.

You can skip PBS for a small lab (< 3 VMs). You cannot skip the
NAS. You cannot skip the off-site copy.
