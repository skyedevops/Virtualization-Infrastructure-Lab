#!/usr/bin/env bash
# pbs-backup.sh - run a PBS backup for one or all VMs in the lab.
#
# Mirrors `labctl backup` but as a stand-alone bash script (no Python
# dependency), callable from cron on the PVE node.  Reads the same
# lab.yaml as labctl.py.
#
# Usage:
#   pbs-backup.sh [--lab lab.yaml] [--vm VMNAME] [--execute] [--pve-node NAME]
#
# Without --vm, runs every enabled backup job in lab.yaml.  Without
# --execute, prints the commands it would run (dry-run).  --pve-node
# pins which PVE node runs the backup (defaults to the VM's
# `hypervisor:` field, i.e. "run it where the VM lives").
#
# Exit code:
#   0  all backups + prunes succeeded (or dry-run printed)
#   1  one or more jobs failed
#   2  usage / yaml error

set -euo pipefail

LAB="${LAB:-lab.yaml}"
VM_FILTER=""
EXECUTE=0
PVE_NODE=""

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lab)       LAB="$2"; shift 2 ;;
    --vm)        VM_FILTER="$2"; shift 2 ;;
    --pve-node)  PVE_NODE="$2"; shift 2 ;;
    --execute)   EXECUTE=1; shift ;;
    -h|--help)   usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -r "$LAB" ]] || { echo "error: cannot read $LAB" >&2; exit 2; }

# Use python3 + labctl.py to resolve jobs into a stream of shell
# commands.  Same approach the v2.0 runbooks take.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABCTL_PY="$(cd "$SCRIPT_DIR/.." && pwd)/python/labctl.py"
if [[ ! -r "$LABCTL_PY" ]]; then
  echo "error: labctl.py not found at $LABCTL_PY" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not on PATH" >&2
  exit 2
fi

# Collect every "  $ ..." line from `labctl backup` for jobs we want
# to run.  Filter by --vm if given.
filter_jobs() {
  if [[ -n "$VM_FILTER" ]]; then
    grep -E "(vm=$VM_FILTER )"
  else
    cat
  fi
}
mapfile -t LINES < <(python3 "$LABCTL_PY" --lab "$LAB" backup \
  | grep -E '^(# job |  \$ )' \
  | filter_jobs )

if [[ ${#LINES[@]} -eq 0 ]]; then
  echo "no matching backup jobs in $LAB"
  exit 0
fi

echo "found ${#LINES[@]} job line(s)"

# Optional: pin the source PVE node.  We rewrite --node in the
# emitted backup command.  This is a no-op if the lab already has the
# right node.
pin_node() {
  local line="$1"
  if [[ -n "$PVE_NODE" ]]; then
    # Replace --node <x> with --node $PVE_NODE
    line=$(printf '%s' "$line" | sed -E "s/--node [a-zA-Z0-9_.-]+/--node $PVE_NODE/")
  fi
  printf '%s\n' "$line"
}

ran=0
failed=0
for raw in "${LINES[@]}"; do
  if [[ "$raw" == "# job "* ]]; then
    echo
    echo "$raw"
    continue
  fi
  # raw looks like: "  $ proxmox-backup-manager backup ..."
  cmd=${raw#"  $ "}
  cmd=$(pin_node "$cmd")
  if (( ! EXECUTE )); then
    echo "[dry-run] $cmd"
    continue
  fi
  echo "[run] $cmd"
  if eval "$cmd"; then
    ran=$((ran+1))
  else
    echo "[FAIL] rc=$?: $cmd" >&2
    failed=$((failed+1))
  fi
done

if (( ! EXECUTE )); then
  echo
  echo "[--] dry-run. Pass --execute to actually run the backups." >&2
  exit 0
fi
echo
echo "[ok] $ran job(s) ran, $failed failed"
exit $(( failed > 0 ))
