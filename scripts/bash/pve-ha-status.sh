#!/usr/bin/env bash
# pve-ha-status.sh - print a single-page HA status report for a Proxmox
# cluster.  Designed to be run from any cluster member (or the operator's
# laptop, with `ssh pve01 'bash -s' < pve-ha-status.sh`).
#
# Usage:
#   pve-ha-status.sh [NODE]
#
# NODE defaults to "pve01" if not given.  The script does not require any
# arguments; it auto-discovers cluster members via `pvecm status` and
# queries `ha-manager status` on each one.
#
# Exit code:
#   0  cluster healthy
#   1  one or more VMs are not in "started" state
#   2  usage / SSH / unknown error

set -euo pipefail

NODE="${1:-pve01}"
SSH_USER="${PVE_SSH_USER:-root}"
SSH_TARGET="${SSH_USER}@${NODE}"

# Colour helpers (auto-disabled on non-tty)
if [[ -t 1 ]]; then
  C_OK=$'\033[1;32m'; C_FAIL=$'\033[1;31m'; C_WARN=$'\033[1;33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=''; C_FAIL=''; C_WARN=''; C_DIM=''; C_RST=''
fi

say() { printf '%s\n' "$*"; }
err() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }

require() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "missing: $c"; exit 2; }
  done
}
require ssh

say "${C_DIM}--- cluster membership (pvecm status) ---${C_RST}"
ssh "$SSH_TARGET" pvecm status 2>/dev/null \
  | grep -E '^\s*(Name|Member ID|Vote|Status|Nodes)' \
  | head -40 || err "pvecm status failed on $NODE"

# Discover cluster members
NODES=$(ssh "$SSH_TARGET" pvecm status 2>/dev/null \
  | awk '/^0x/ && $3 != 0 {print $3}' | sort -u)
if [[ -z "$NODES" ]]; then
  # Fallback: ask for the members via getcluster
  NODES=$(ssh "$SSH_TARGET" 'pvecm nodes 2>/dev/null | awk "/^[[:space:]]*[0-9]+/{print \$3}"' || true)
fi
if [[ -z "$NODES" ]]; then
  err "could not enumerate cluster members via $NODE"
  exit 2
fi

say
say "${C_DIM}--- ha-manager status (per node) ---${C_RST}"
TOTAL=0
BAD=0
for n in $NODES; do
  say "${C_DIM}>> ${SSH_USER}@${n}${C_RST}"
  out=$(ssh "${SSH_USER}@${n}" 'ha-manager status' 2>&1) || { err "ssh $n failed"; BAD=$((BAD+1)); continue; }
  if [[ -z "$out" ]]; then
    say "  (no HA resources)"
    continue
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    TOTAL=$((TOTAL+1))
    if [[ "$line" == *"fenced"* || "$line" == *"error"* || "$line" == *"stopped"* ]]; then
      say "  ${C_FAIL}${line}${C_RST}"
      BAD=$((BAD+1))
    elif [[ "$line" == *"started"* ]]; then
      say "  ${C_OK}${line}${C_RST}"
    else
      say "  ${C_WARN}${line}${C_RST}"
    fi
  done <<< "$out"
done

say
if (( BAD == 0 )); then
  say "${C_OK}All ${TOTAL} HA resource(s) healthy.${C_RST}"
  exit 0
else
  say "${C_FAIL}${BAD} of ${TOTAL} HA resource(s) not in 'started' state.${C_RST}"
  exit 1
fi
