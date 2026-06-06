# Project Roadmap

A living document. Dates are estimates, not commitments. Items move
between lists as work progresses.

---

## Status Snapshot

| Phase | Status | Released |
|-------|--------|----------|
| **v1.0 - Initial Lab Build** | Complete | `bf355d2` |
| **v1.1 - Video Script + Trade-off Docs** | Complete | `2ae4f81` |
| **v1.2 - Roadmap** | In progress | this commit |
| **v1.3 - Diagrams** | Complete | this commit |
| **v1.4 - Lab-in-a-Box Bootstrap** | Planned | - |
| **v2.0 - Multi-Host Proxmox Cluster** | Planned | - |
| **v2.1 - Proxmox Backup Server** | Planned | - |
| **v2.2 - Observability Stack** | Planned | - |
| **v2.3 - IaC with Terraform + Ansible** | Planned | - |
| **v3.0 - DR Drills + SLO Testing** | Planned | - |
| **v3.1 - Security Hardening Pass** | Planned | - |
| **v3.2 - Performance Benchmarks** | Planned | - |
| **v4.0 - Public Terraform Module / Packer Catalog** | Stretch | - |

---

## v1.x - Repository Maturity (near term)

Documentation and reproducibility polish. No new lab hardware.

### v1.3 - Architecture Diagrams
- [x] Mermaid / draw.io source for the topology in `docs/lab-topology.md`
- [x] Sequence diagram for DR restore (Scenario 2)
- [x] Diagram for Proxmox VM-to-physical bridge mapping
- [x] Per-hypervisor network stack diagram (VLAN/bridge/port)

### v1.4 - Lab-in-a-Box Bootstrap
- [ ] `make` / `make.ps1` targets: `init`, `vm`, `backup`, `restore`, `drill`, `destroy`
- [ ] Single-file inventory of every VM in the lab (`lab.yaml`)
- [ ] Idempotent `bootstrap.sh` / `bootstrap.ps1` that builds a fresh lab from scratch
- [ ] Test on a clean VM at least once

### v1.5 - CI for the Scripts
- [ ] GitHub Actions: bash `shellcheck`, python `ruff`/`pytest`, powershell `PSScriptAnalyzer`
- [ ] Markdown lint for the docs
- [ ] PR template that requires the relevant doc be updated when a script changes
- [ ] All existing scripts passing the linters

---

## v2.x - Lab Capability Expansion

New infrastructure, same repo conventions.

### v2.0 - Multi-Host Proxmox Cluster
- [ ] Stand up a 3-node Proxmox cluster (current node + 2 added)
- [ ] Document Ceph vs NFS shared storage choice with cost/perf trade-off
- [ ] HA tests: `ha-manager` + simulated node failure
- [ ] Live-migration demo + runbook entry

### v2.1 - Proxmox Backup Server (PBS)
- [ ] Dedicated PBS VM on NAS or separate mini-PC
- [ ] PBS datastore add on each PVE node
- [ ] Backup jobs with deduplicated, encrypted, incremental-forever snapshots
- [ ] `restore-test` job that pulls a random backup nightly and boots it in an isolated VLAN

### v2.2 - Observability Stack
- [ ] Prometheus + node_exporter on every VM (Linux, Windows exporter for Windows guests)
- [ ] Grafana dashboards: hypervisor health, VM density, storage growth, backup freshness
- [ ] Loki or similar for centralized log aggregation
- [ ] Alertmanager rules wired to Discord webhook

### v2.3 - Infrastructure as Code
- [ ] Terraform provider for Proxmox - VM definitions in HCL
- [ ] Ansible roles for Linux VM baseline (currently in shell script)
- [ ] Windows baseline in Ansible (currently in PowerShell)
- [ ] Drift detection: nightly `terraform plan` against live state

---

## v3.x - Hardening & SLOs

Making the lab operationally honest, not just functional.

### v3.0 - DR Drills + SLO Testing
- [ ] Quarterly DR drill log (`snapshots-backup/recovery-drills.md`)
- [ ] RPO/RTO targets per VM tier, measured vs. achieved
- [ ] Chaos tests: `tc netem` packet loss / latency, forced host reboot, network partition
- [ ] Public runbook: "the lab caught a real bug on date X because of drill Y"

### v3.1 - Security Hardening Pass
- [ ] CIS Benchmark scan for Ubuntu / Rocky / Windows Server (free scanners)
- [ ] `auditd` rules for Linux, Advanced Audit for Windows
- [ ] WireGuard VPN for remote lab access (already covered in pfSense doc; expand)
- [ ] Suricata or Snort on pfSense DMZ interface

### v3.2 - Performance Benchmarks
- [ ] fio disk benchmarks on each tier (NVMe, SATA SSD, NAS)
- [ ] iperf3 between hosts, between VLANs, between virtual switches
- [ ] Compare VM disk performance across hypervisors on the same workload
- [ ] Publish results in `resource-management/benchmarks.md`

---

## v4.x - Community / Reuse (stretch goals)

Only after v3 is complete.

### v4.0 - Public Terraform Module / Packer Catalog
- [ ] Reusable Terraform module: `terraform-proxmox-lab-vm`
- [ ] Packer templates for Linux (Ubuntu, Rocky) + Windows Server golden images
- [ ] GitHub Pages site rendered from `docs/` with mkdocs-material
- [ ] Issue templates and CONTRIBUTING.md for community PRs

---

## Contributing

Open a PR or an issue with the `roadmap/` label to propose new items.
Items that are out of scope for the current phase should still be
captured here with a phase and priority.

### Priority Definitions

| Priority | Meaning |
|----------|---------|
| **P0** | Blocks the next phase, do first |
| **P1** | Important for the current phase |
| **P2** | Nice to have, queue it |
| **P3** | Stretch / research only |

### Out of Scope (for now)

- Bare-metal ESXi + vCenter - licensing makes this non-portable
- Public cloud mirroring (AWS / Azure) - costs money, low learning value
- Production customer workloads - this is a lab
- macOS as a Type-2 hypervisor host - not enough coverage
- Mobile / ARM hypervisors - different ISA, separate problem
