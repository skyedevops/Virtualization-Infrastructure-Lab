# Architecture Diagrams

All diagrams are Mermaid source so they render natively on GitHub and
in mkdocs-material. To preview locally:

```bash
# VS Code: install the "Markdown Preview Mermaid Support" extension
# Or: https://mermaid.live  (paste the ```mermaid block)
```

## Index

| Diagram | File | What it shows |
|---------|------|---------------|
| Physical topology | [physical-topology.md](physical-topology.md) | Devices, NICs, physical wiring |
| VLAN / logical topology | [vlan-topology.md](vlan-topology.md) | Subnets, gateway, DHCP ranges, service placement |
| Hypervisor network stack | [hypervisor-network-stacks.md](hypervisor-network-stacks.md) | Side-by-side: how each hypervisor models vSwitches/bridges |
| DR restore flow (Scenario 2) | [dr-restore-flow.md](dr-restore-flow.md) | Sequence of a single-VM restore from backup |
| Backup data flow | [backup-data-flow.md](backup-data-flow.md) | Local snapshot -> NAS -> off-site B2 |

## Conventions

- **Solid arrow** = data plane
- **Dashed arrow** = control plane (API / mgmt)
- **Blue** = physical
- **Green** = hypervisor management
- **Orange** = VM data
- **Red** = backup/recovery path
