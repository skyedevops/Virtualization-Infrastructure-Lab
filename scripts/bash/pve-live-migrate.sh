#!/usr/bin/env bash
# pve-live-migrate.sh - live-migrate a VM (or all VMs) from one Proxmox
# cluster node to another.  Pure bash; the equivalent of the labctl
# `migrate` subcommand but standalone, with extra safety:
#
#   - refuses to migrate HA-managed VMs without --force (HA will
#     just bring them back if the source node is alive)
#   - waits for the migration to actually complete
#   - prints before/after `qm list` snapshots
#
# Usage:
#   pve-live-migrate.sh --vm VMID --from NODE --to NODE [--force] [--wait]
#   pve-live-migrate.sh --all --from NODE --to NODE [--force] [--wait]
#
# Exit code:
#   0  all migrations succeeded
#   1  one or more migrations failed
#   2  usage / SSH error

set -euo pipefail

SSH_USER="${PVE_SSH_USER:-root}"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

VMID="" FROM="" TO="" FORCE=0 WAIT=0 MIGRATE_ALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)    VMID="$2"; shift 2 ;;
    --from)  FROM="$2"; shift 2 ;;
    --to)    TO="$2";   shift 2 ;;
    --all)   MIGRATE_ALL=1; shift ;;
    --force) FORCE=1; shift ;;
    --wait)  WAIT=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$FROM" && -n "$TO" ]] || usage
[[ "$FROM" != "$TO" ]] || { echo "error: --from and --to must differ" >&2; exit 2; }
if (( ! MIGRATE_ALL )); then
  [[ -n "$VMID" ]] || usage
fi

ssh_qm() {
  # Run a command on the remote host.  Builds a single shell-quoted
  # string so that the words are reconstructed on the remote side.
  local remote="${SSH_USER}@${1}"; shift
  local q
  q=$(printf '%q ' "$@")
  # shellcheck disable=SC2029  # we just shell-quoted above
  ssh "$remote" "$q"
}

check_reachable() {
  local node="$1"
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_USER}@${node}" true 2>/dev/null; then
    echo "error: cannot ssh to ${SSH_USER}@${node}" >&2
    exit 2
  fi
}

check_reachable "$FROM"
check_reachable "$TO"

# Resolve VM list
if (( MIGRATE_ALL )); then
  mapfile -t VMIDS < <(ssh_qm "$FROM" 'qm list' | awk 'NR>1 {print $1}')
  [[ ${#VMIDS[@]} -gt 0 ]] || { echo "no VMs on $FROM"; exit 1; }
  echo "Migrating ${#VMIDS[@]} VM(s) from $FROM -> $TO"
else
  VMIDS=("$VMID")
fi

# Safety check: HA-managed VMs
if (( ! FORCE )); then
  ha_out=$(ssh_qm "$FROM" 'ha-manager status' 2>/dev/null || true)
  ha_vms=()
  while IFS= read -r line; do
    [[ "$line" =~ ^([0-9]+) ]] && ha_vms+=("${BASH_REMATCH[1]}")
  done <<< "$ha_out"
  for v in "${VMIDS[@]}"; do
    if printf '%s\n' "${ha_vms[@]}" | grep -qx "$v"; then
      echo "error: VM $v is HA-managed; refusing to migrate without --force" >&2
      echo "       (HA will move it back if $FROM stays online)" >&2
      exit 1
    fi
  done
fi

# Snapshot before
echo "--- before migration (on $FROM) ---"
ssh_qm "$FROM" 'qm list'

# Migrate
failed=0
for v in "${VMIDS[@]}"; do
  echo
  echo ">> migrating $v : $FROM -> $TO"
  if ! ssh_qm "$FROM" "qm migrate $v $TO online"; then
    echo "   FAIL: qm migrate $v $TO"
    failed=$((failed+1))
    continue
  fi
  if (( WAIT )); then
    echo "   waiting for $v to settle on $TO ..."
    deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
      cur=$(ssh_qm "$TO" qm list | awk -v v="$v" '$1==v{print $3}')
      if [[ -n "$cur" ]]; then
        echo "   $v is on $TO (status=$cur)"
        break
      fi
      sleep 2
    done
  fi
done

# Snapshot after
echo
echo "--- after migration (on $TO) ---"
ssh_qm "$TO" 'qm list'

if (( failed > 0 )); then
  echo
  echo "$failed migration(s) FAILED."
  exit 1
fi
echo
echo "All migrations OK."
