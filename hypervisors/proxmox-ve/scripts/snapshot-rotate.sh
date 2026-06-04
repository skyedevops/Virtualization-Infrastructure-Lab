#!/usr/bin/env bash
# snapshot-rotate.sh
# Daily snapshot creation + retention for all running KVM VMs and LXC containers.
# Pairs with snapshot-rotate.timer/.service systemd units.

set -euo pipefail

RETAIN_DAILY="${RETAIN_DAILY:-7}"
RETAIN_WEEKLY="${RETAIN_WEEKLY:-4}"
PREFIX_DAILY="auto-daily"
PREFIX_WEEKLY="auto-weekly"
STAMP=$(date +%Y%m%d-%H%M)
DOW=$(date +%u)   # 1..7 (Mon..Sun)
LOG=/var/log/pve-snapshot-rotate.log

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG"; }

snapshot_one() {
  local kind="$1" id="$2" name="$3"
  local cmd
  case "$kind" in
    qm)  cmd="qm" ;;
    pct) cmd="pct" ;;
    *) log "Unknown kind $kind"; return 1 ;;
  esac

  log "[$kind $id] snapshot $name"
  if ! "$cmd" snapshot "$id" "$name" --description "auto $(date -Is)" 2>>"$LOG"; then
    log "[$kind $id] snapshot FAILED"
    return 1
  fi
}

prune_snapshots() {
  local kind="$1" id="$2" prefix="$3" keep="$4"
  local cmd snaps to_delete
  case "$kind" in
    qm)  cmd="qm listsnapshot $id"  ;;
    pct) cmd="pct listsnapshot $id" ;;
  esac

  # Lines look like:  `-> auto-daily-20260103-0300   Some desc   2026-01-03 ...
  mapfile -t snaps < <($cmd 2>/dev/null \
    | awk -v p="$prefix" '$0 ~ p {for(i=1;i<=NF;i++) if($i ~ p) {print $i; next}}' \
    | sort)

  if (( ${#snaps[@]} <= keep )); then return 0; fi

  to_delete=("${snaps[@]:0:${#snaps[@]}-keep}")
  for s in "${to_delete[@]}"; do
    log "[$kind $id] pruning $s"
    case "$kind" in
      qm)  qm delsnapshot  "$id" "$s" 2>>"$LOG" || true ;;
      pct) pct delsnapshot "$id" "$s" 2>>"$LOG" || true ;;
    esac
  done
}

log "===== snapshot-rotate run start ====="
log "Retain daily=$RETAIN_DAILY weekly=$RETAIN_WEEKLY"

# Decide today's tag(s)
TAGS=("${PREFIX_DAILY}-${STAMP}")
if [[ $DOW -eq 7 ]]; then
  TAGS+=("${PREFIX_WEEKLY}-${STAMP}")
fi

# KVM VMs
for id in $(qm list | awk 'NR>1 {print $1}'); do
  for tag in "${TAGS[@]}"; do
    snapshot_one qm "$id" "$tag" || continue
  done
  prune_snapshots qm "$id" "$PREFIX_DAILY"  "$RETAIN_DAILY"
  prune_snapshots qm "$id" "$PREFIX_WEEKLY" "$RETAIN_WEEKLY"
done

# LXC containers
for id in $(pct list | awk 'NR>1 {print $1}'); do
  for tag in "${TAGS[@]}"; do
    snapshot_one pct "$id" "$tag" || continue
  done
  prune_snapshots pct "$id" "$PREFIX_DAILY"  "$RETAIN_DAILY"
  prune_snapshots pct "$id" "$PREFIX_WEEKLY" "$RETAIN_WEEKLY"
done

log "===== snapshot-rotate run end ====="
