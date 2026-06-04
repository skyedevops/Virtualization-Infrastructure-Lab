#!/usr/bin/env bash
# backup-all-vms.sh
# Run vzdump on every KVM VM and LXC container, store on the named storage,
# and enforce a retention policy.

set -euo pipefail

STORAGE="${STORAGE:-nas-backup}"     # must be a configured pve storage with 'backup' content
MODE="${MODE:-snapshot}"             # snapshot | suspend | stop
COMPRESS="${COMPRESS:-zstd}"         # gzip | lzo | zstd
MAILTO="${MAILTO:-root}"
MAILNOT="${MAILNOTIFICATION:-failure}"   # always | failure
KEEP_LAST="${KEEP_LAST:-3}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
LOG=/var/log/pve-backup-all.log

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG"; }

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

log "===== backup-all-vms start ====="
log "Storage=$STORAGE mode=$MODE compress=$COMPRESS"

# Verify storage exists and accepts backups
if ! pvesm status -storage "$STORAGE" >/dev/null 2>&1; then
  log "ERROR: storage '$STORAGE' not configured. pvesm add nfs ... first."
  exit 2
fi

# Collect all guest IDs (VMs + CTs)
mapfile -t IDS < <(
  { qm list | awk 'NR>1 {print $1}'; pct list | awk 'NR>1 {print $1}'; } | sort -n -u
)
if (( ${#IDS[@]} == 0 )); then log "No VMs/CTs found."; exit 0; fi
log "Targets: ${IDS[*]}"

# Run vzdump in --all mode with explicit retention
vzdump --all 1 \
       --storage "$STORAGE" \
       --mode "$MODE" \
       --compress "$COMPRESS" \
       --mailto "$MAILTO" \
       --mailnotification "$MAILNOT" \
       --prune-backups "keep-last=$KEEP_LAST,keep-daily=$KEEP_DAILY,keep-weekly=$KEEP_WEEKLY,keep-monthly=$KEEP_MONTHLY" \
       --quiet 1 \
       2>&1 | tee -a "$LOG"

rc=${PIPESTATUS[0]}
log "===== backup-all-vms end (rc=$rc) ====="
exit "$rc"
