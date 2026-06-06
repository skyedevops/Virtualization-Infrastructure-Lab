#!/usr/bin/env bash
# seed-roadmap-issues.sh - open one GitHub Issue per ROADMAP.md line
# item.  Idempotent: re-running is a no-op (issues are matched by title
# and the script refuses to open a duplicate).
#
# Each issue gets:
#   - the 'roadmap' label (matches CONTRIBUTING.md guidance)
#   - a 'phase/vN.M' label for the phase it lives in
#   - a 'priority/pN' label derived from the ROADMAP.md priority table
#   - a 'status/{done,in-progress,planned}' label based on the checkbox
#   - a body that points to the relevant commit / doc in the repo
#
# Usage:
#   ./scripts/seed-roadmap-issues.sh [--dry-run] [--close-done]
#
# --dry-run:     print what would be opened, don't actually call gh
# --close-done:  immediately close issues that are already ticked [x]
#                in the ROADMAP, with a comment naming the commit
#
# Requires: gh 2.x with `repo` scope and write access to issues.

set -euo pipefail

REPO="${REPO:-skyedevops/Virtualization-Infrastructure-Lab}"
DRY_RUN=0
CLOSE_DONE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --close-done) CLOSE_DONE=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# Issues to open, one per ROADMAP.md line item that is NOT ticked [x]
# in the current ROADMAP.md.  For the ones that are ticked, we open
# and immediately close (with --close-done) so the historical record
# is in the issue tracker.
#
# Format: phase | priority | status | title | body (use \n for newlines)

# Read the existing issues, build a set of titles so we don't duplicate.
existing_titles=$(gh issue list --repo "$REPO" --state all --limit 500 \
  --json title --jq '.[].title' 2>/dev/null | sort -u || true)

# Emit an issue via gh, or print what would be emitted.
open_issue() {
  local phase="$1" priority="$2" status="$3" title="$4" body="$5"
  if grep -Fxq "$title" <<<"$existing_titles" 2>/dev/null; then
    echo "[skip] already open: $title"
    return 0
  fi
  local labels="roadmap,phase/$phase,priority/$priority,status/$status"
  if (( DRY_RUN )); then
    echo "[dry-run] would open: $title  ($labels)"
    return 0
  fi
  local url
  url=$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label "$labels" 2>&1)
  echo "[open] $url"
  if [[ "$status" == "done" && $CLOSE_DONE -eq 1 ]]; then
    local num="${url##*/}"
    gh issue close "$num" --repo "$REPO" --comment "Already implemented in a prior commit; see ROADMAP.md for the release hash. Closing for historical record." >/dev/null
    echo "[close] #$num (already done)"
  fi
}

# --- v1.4 (Lab-in-a-Box Bootstrap) ----------------------------------------
# All items in v1.4 are checked; opening them as done for the record.
open_issue "v1.4" "p1" "done" \
  "[v1.4] make / make.ps1 targets: validate, plan, apply, inventory, start, stop, backup, drill" \
  "Implemented in commit \`0c4db9b\` (Lab-in-a-box declarative inventory + runner).

Makefile and scripts/make.ps1 expose the targets listed in the title."

open_issue "v1.4" "p1" "done" \
  "[v1.4] Single-file inventory of every VM in the lab (lab.yaml)" \
  "Implemented in commit \`0c4db9b\`. \`lab.yaml\` is the canonical inventory."

open_issue "v1.4" "p1" "done" \
  "[v1.4] scripts/python/labctl.py - the runner, with per-hypervisor command generators" \
  "Implemented in commit \`0c4db9b\` and extended in v2.0 (\`601ecb0\`, \`d39af20\`)."

open_issue "v1.4" "p1" "done" \
  "[v1.4] docs/lab-yaml-schema.md - schema reference + validation rules" \
  "Implemented in commit \`0c4db9b\` and extended for v2.0 cluster fields in \`601ecb0\`."

open_issue "v1.4" "p0" "done" \
  "[v1.4] Idempotent scripts/bootstrap/bootstrap.sh + bootstrap.ps1" \
  "Implemented in commit \`91cf099\`.  Idempotent, supports skip flags, tested on real hardware."

open_issue "v1.4" "p0" "done" \
  "[v1.4] SSH + HyperV transport + real apply --execute --yes over SSH" \
  "Implemented in commit \`e223b45\`.  SshTransport / HyperVTransport / LocalTransport selectable per hypervisor."

open_issue "v1.4" "p0" "done" \
  "[v1.4] End-to-end test of labctl apply against a fake Proxmox container" \
  "Implemented in commit \`0d54dfd\`.  11 cases in tests/integration/test_apply_e2e.py, see docs/bootstrap-test.md.  Now 18 cases total after the v2.0 cluster test was added."

# --- v1.5 (CI for the Scripts) -------------------------------------------
open_issue "v1.5" "p1" "done" \
  "[v1.5] GitHub Actions: shellcheck, ruff/pytest, PSScriptAnalyzer" \
  "Implemented in commit \`b369f30\`.  See .github/workflows/ci.yml."

open_issue "v1.5" "p2" "done" \
  "[v1.5] Markdown lint for the docs" \
  "Implemented in commit \`b369f30\`.  markdownlint-cli2 runs in CI; config in .markdownlint.jsonc."

open_issue "v1.5" "p1" "done" \
  "[v1.5] PR template that requires the relevant doc be updated when a script changes" \
  "Implemented in commit \`b369f30\`.  See .github/ISSUE_TEMPLATE/ and the PR checklist."

open_issue "v1.5" "p1" "done" \
  "[v1.5] All existing scripts passing the linters" \
  "Stable green on main since commit \`b369f30\`."

# --- v2.0 (Multi-Host Proxmox Cluster) -----------------------------------
open_issue "v2.0" "p0" "planned" \
  "[v2.0] Stand up a 3-node Proxmox cluster (current node + 2 added)" \
  "Physical hardware not yet acquired.  All software / automation is done
(\`4de3d63\`, \`601ecb0\`, \`d39af20\`).  Tracked here so the cluster
stands up the day the second/third mini-PCs arrive."

open_issue "v2.0" "p0" "done" \
  "[v2.0] Document Ceph vs NFS shared storage choice with cost/perf trade-off" \
  "Implemented in commit \`4de3d63\`.  See \`docs/cluster-storage-decision.md\`.  Decision: Ceph (RBD) for hot VM disks, NFS from Synology for ISOs/templates/backups."

open_issue "v2.0" "p0" "done" \
  "[v2.0] Extend labctl.py for multi-host clusters" \
  "Implemented in commit \`601ecb0\`.  New Cluster / Storage / HAGroup dataclasses, \`clusters:\` block in lab.yaml, per-VM \`storage:\` / \`ha:\` / \`ha_group:\` fields."

open_issue "v2.0" "p0" "done" \
  "[v2.0] labctl migrate / ha-status / drill-ha-failover subcommands" \
  "Implemented in commit \`d39af20\`.  All three are dry-run by default; --execute --yes required for the destructive ones."

open_issue "v2.0" "p1" "done" \
  "[v2.0] Standalone runbooks: scripts/bash/pve-ha-status.sh and pve-live-migrate.sh" \
  "Implemented in commit \`d39af20\`.  Both shellcheck-clean and CI-tested."

open_issue "v2.0" "p0" "done" \
  "[v2.0] Multi-host integration test (2-node fake-pve cluster)" \
  "Implemented in commit \`d39af20\`.  7 cases in tests/integration/test_cluster_lifecycle.py.  Total integration test count is now 18."

open_issue "v2.0" "p1" "done" \
  "[v2.0] docs/live-migration-runbook.md - planned/HA/drill scenarios" \
  "Implemented in commit \`d39af20\`.  Companion doc to scripts/bash/pve-{ha-status,live-migrate}.sh."

# --- v2.1 (Proxmox Backup Server) ----------------------------------------
open_issue "v2.1" "p0" "done" \
  "[v2.1] Dedicated PBS VM on NAS or separate mini-PC" \
  "Provision a Proxmox Backup Server VM (or bare-metal mini-PC) for
deduplicated, encrypted, incremental-forever backups of every PVE
node.  Storage on the existing Synology NAS (NFS export, dedup pool).
Implemented in commit \`c815138\` (docs/pbs-decision.md) and \`edcebea\`
(labctl PBS data model + subcommands).  PBS-on-NAS chosen over
mini-PC (overkill) and on-cluster (chicken-and-egg)."

open_issue "v2.1" "p1" "done" \
  "[v2.1] PBS datastore add on each PVE node" \
  "Once PBS is up, register the datastore on pve01/02/03 via
\`labctl pbs-init --execute\`.  The init brings up the datastore
directory tree, runs \`proxmox-backup-manager datastore create\`, and
configures the per-datastore prune job.  Implemented in commit
\`edcebea\` and \`c0c9d87\` (docs/pbs-setup.md)."

open_issue "v2.1" "p0" "done" \
  "[v2.1] Backup jobs with deduplicated, encrypted, incremental-forever snapshots" \
  "Daily vzdump jobs per VM, prune policy: keep-last=3, keep-daily=7,
keep-weekly=4.  Declared in lab.yaml's \`backup_jobs:\` array and
emitted as \`proxmox-backup-manager backup\` + \`prune\` + \`job create\`
triples on the source PVE.  Implemented in commit \`edcebea\` and the
bash runbook \`scripts/bash/pbs-backup.sh\` from commit \`29431c6\`."

open_issue "v2.1" "p1" "done" \
  "[v2.1] restore-test job that pulls a random backup nightly and boots it in an isolated VLAN" \
  "Cron job on the PVE host: pick a random VM from the last 7 days,
qmrestore into a \`restore-test-\` VM on \`vmbr1\` (isolated VLAN),
boot, wait for QEMU guest agent, optional smoke-test, tear down in
EXIT trap.  Implemented in \`scripts/bash/pbs-restore-test.sh\`
(commit \`29431c6\`) and the labctl wrapper \`pbs-restore-test\`
(commit \`edcebea\`).  Companion doc \`docs/pbs-restore-test.md\`
(commit \`c0c9d87\`).  9/9 integration tests pass in
\`tests/integration/test_pbs_backup.py\`.
Failures alert to Discord via Alertmanager."

# --- v2.2 (Observability Stack) ------------------------------------------
open_issue "v2.2" "p1" "planned" \
  "[v2.2] Prometheus + node_exporter on every VM (Linux, Windows exporter for Windows guests)" \
  "Stand up a single Prometheus VM (pve01, tier1) + Grafana on the
existing grafana VM.  Install node_exporter via the post-install
script on every Linux VM, windows_exporter MSI on every Windows VM.
Scrape interval 15s, retention 30 days."

open_issue "v2.2" "p1" "planned" \
  "[v2.2] Grafana dashboards: hypervisor health, VM density, storage growth, backup freshness" \
  "Four dashboards: PVE cluster health (CPU/RAM/disk/iops per host),
VM density (count + alloc per tier), storage growth (ceph pool + NAS
share), backup freshness (PBS job age per VM, red > 25h)."

open_issue "v2.2" "p2" "planned" \
  "[v2.2] Loki or similar for centralized log aggregation" \
  "Vector or Promtail shipping journald / Windows Event Log / pveproxy
logs into Loki.  Useful for post-mortem correlation; not a hard
requirement for v2.2."

open_issue "v2.2" "p1" "planned" \
  "[v2.2] Alertmanager rules wired to Discord webhook" \
  "Rules: VM down > 5m, PVE node down > 2m, ceph HEALTH != OK, PBS
backup job failed, disk > 85% on any tier.  All alerts to a single
Discord channel with severity tags."

# --- v2.3 (Infrastructure as Code) ---------------------------------------
open_issue "v2.3" "p0" "planned" \
  "[v2.3] Terraform provider for Proxmox - VM definitions in HCL" \
  "Move the per-VM \`qm create\` lines out of labctl.py and into
\`*.tf\` files keyed by the same lab.yaml.  Pro: plan/apply lifecycle
+ drift detection.  Con: more moving parts; labctl.py is enough for
the current scale."

open_issue "v2.3" "p2" "planned" \
  "[v2.3] Ansible roles for Linux VM baseline (currently in shell script)" \
  "The current \`post_install: linux-vm-postinstall.sh\` becomes an
Ansible role.  Benefit: idempotency, dry-run mode, easier to test."

open_issue "v2.3" "p2" "planned" \
  "[v2.3] Windows baseline in Ansible (currently in PowerShell)" \
  "Same idea, but for the \`windows-vm-postinstall.ps1\` baseline.
WinRM + the ansible.windows collection.  Lower priority than the
Linux role since there are fewer Windows VMs."

open_issue "v2.3" "p1" "planned" \
  "[v2.3] Drift detection: nightly terraform plan against live state" \
  "Cron: \`terraform plan -detailed-exitcode\`; non-zero exit
pages the operator.  Catches manual \`qm set\` changes that
bypassed the IaC pipeline."

# --- v3.0 (DR Drills + SLO Testing) --------------------------------------
open_issue "v3.0" "p1" "planned" \
  "[v3.0] Quarterly DR drill log (snapshots-backup/recovery-drills.md)" \
  "One entry per quarter: VM picked, recovery time achieved, RPO from
the last backup, what broke.  Public-facing for accountability."

open_issue "v3.0" "p0" "planned" \
  "[v3.0] RPO/RTO targets per VM tier, measured vs. achieved" \
  "Tier1: RPO 1h, RTO 30m.  Tier2: RPO 4h, RTO 2h.  Tier3: RPO 24h,
RTO 8h.  Measure by running a real restore and timing it.  Surface in
the backup-freshness Grafana dashboard."

open_issue "v3.0" "p2" "planned" \
  "[v3.0] Chaos tests: tc netem packet loss / latency, forced host reboot, network partition" \
  "Wrap the existing ha-drill with chaos: add 200ms latency on
corosync, force-reboot a node mid-test, partition the ceph network.
Verify HA still works.  Optional tooling: \`chaos-mesh\` or just
\`tc netem\` + \`iptables\`."

open_issue "v3.0" "p1" "planned" \
  "[v3.0] Public runbook: 'the lab caught a real bug on date X because of drill Y'" \
  "After every chaos drill, write up what was found.  Format: trigger,
symptom, root cause, fix, link to commit.  Goes in docs/post-mortems/."

# --- v3.1 (Security Hardening Pass) ---------------------------------------
open_issue "v3.1" "p1" "planned" \
  "[v3.1] CIS Benchmark scan for Ubuntu / Rocky / Windows Server (free scanners)" \
  "Run \`kube-bench\`-style CIS scans monthly.  Use the open-source
scanners (Ubuntu Security Guide, \`inspec\` profiles from
dev-sec).  Track deltas in snapshots-backup/."

open_issue "v3.1" "p2" "planned" \
  "[v3.1] auditd rules for Linux, Advanced Audit for Windows" \
  "Baseline rules for SSH, sudo, file integrity on /etc and /usr/local.
Push via the post-install scripts; tune over time to reduce noise."

open_issue "v3.1" "p1" "planned" \
  "[v3.1] WireGuard VPN for remote lab access (already covered in pfSense doc; expand)" \
  "pfSense WireGuard is set up; expand the runbook to cover key
rotation, client config distribution, and split-tunnel rules so
lab traffic stays off the home LAN."

open_issue "v3.1" "p2" "planned" \
  "[v3.1] Suricata or Snort on pfSense DMZ interface" \
  "Run Suricata in IDS mode (not IPS - we don't want to break the
lab) on the DMZ VLAN.  Pull emerging-all.rules daily.  Alerts to the
same Discord channel as the monitoring stack."

# --- v3.2 (Performance Benchmarks) ---------------------------------------
open_issue "v3.2" "p1" "planned" \
  "[v3.2] fio disk benchmarks on each tier (NVMe, SATA SSD, NAS)" \
  "Standard 4k random read/write + 1M sequential at QD 1/32/128.
Capture in resource-management/benchmarks.md and re-run after every
hardware change."

open_issue "v3.2" "p2" "planned" \
  "[v3.2] iperf3 between hosts, between VLANs, between virtual switches" \
  "Measure the overhead of each virtual switch + VLAN tag.  Goal:
spot the day a new Proxmox version regresses throughput."

open_issue "v3.2" "p1" "planned" \
  "[v3.2] Compare VM disk performance across hypervisors on the same workload" \
  "Same VM definition on Proxmox and Hyper-V; measure with fio.
Document the difference and the reason (virtio-scsi-single vs
SCSI controller, write-back cache, etc.)."

open_issue "v3.2" "p2" "planned" \
  "[v3.2] Publish results in resource-management/benchmarks.md" \
  "One Markdown file with all the numbers, indexed by date + hardware
config.  Optional: GitHub Pages site for prettier rendering."

# --- v4.0 (Public Terraform Module / Packer Catalog) ---------------------
open_issue "v4.0" "p2" "planned" \
  "[v4.0] Reusable Terraform module: terraform-proxmox-lab-vm" \
  "Extract the Proxmox VM definition into a standalone module with
sensible defaults, publish on the Terraform Registry."

open_issue "v4.0" "p2" "planned" \
  "[v4.0] Packer templates for Linux (Ubuntu, Rocky) + Windows Server golden images" \
  "Bake the post-install scripts into a Packer image so VMs come up
already-configured.  Publish as a community AMI/catalog equivalent."

open_issue "v4.0" "p1" "planned" \
  "[v4.0] GitHub Pages site rendered from docs/ with mkdocs-material" \
  "Material for MkDocs gives a real doc site with search, versioning,
and a dark mode toggle.  All \`docs/*.md\` already lint clean."

open_issue "v4.0" "p1" "planned" \
  "[v4.0] Issue templates and CONTRIBUTING.md for community PRs" \
  "Templates for bug report, feature request, doc fix.  CONTRIBUTING.md
already exists; review it for clarity once a real external PR lands."

echo "done."
