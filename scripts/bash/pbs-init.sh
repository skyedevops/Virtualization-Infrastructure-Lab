#!/usr/bin/env bash
# pbs-init.sh - initialise one or more PBS datastores on a PBS host.
#
# Idempotent: safe to re-run.  Existing datastores are left alone,
# prune-jobs are updated to match the desired config.
#
# Usage:
#   pbs-init.sh HOST [--user root] [--port 22] \
#       --datastore NAME --path /path/on/pbs \
#       [--keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 6] \
#       [--prune-run "mon..sat 02:00"] [--execute]
#
# Exit code:
#   0  success (idempotent re-run also returns 0)
#   1  one or more commands failed
#   2  usage / SSH error

set -euo pipefail

HOST=""
SSH_USER=root
SSH_PORT=22
DS_NAME=""
DS_PATH=""
KEEP_LAST=3
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
PRUNE_RUN="mon..sat 02:00"
EXECUTE=0

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) SSH_USER="$2"; shift 2 ;;
    --port) SSH_PORT="$2"; shift 2 ;;
    --datastore) DS_NAME="$2"; shift 2 ;;
    --path) DS_PATH="$2"; shift 2 ;;
    --keep-last) KEEP_LAST="$2"; shift 2 ;;
    --keep-daily) KEEP_DAILY="$2"; shift 2 ;;
    --keep-weekly) KEEP_WEEKLY="$2"; shift 2 ;;
    --keep-monthly) KEEP_MONTHLY="$2"; shift 2 ;;
    --prune-run) PRUNE_RUN="$2"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    -h|--help) usage ;;
    HOST=*) HOST="${1#HOST=}"; shift ;;
    --host) HOST="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$HOST" ]]   || { echo "error: HOST required (or --host)" >&2; exit 2; }
[[ -n "$DS_NAME" ]] || { echo "error: --datastore required" >&2; exit 2; }
[[ -n "$DS_PATH" ]] || { echo "error: --path required" >&2; exit 2; }

SSH_TARGET="${SSH_USER}@${HOST}"
SSH_OPTS=(-p "$SSH_PORT" -o BatchMode=yes
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# Quick SSH reachability
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" true 2>/dev/null; then
  echo "error: cannot ssh to $SSH_TARGET" >&2
  exit 2
fi

# Helper: run a command on the PBS host.  The caller passes a single
# string that the remote shell will evaluate, so word-splitting
# happens on the remote side.  shellcheck can't follow that, so the
# SC2029 info is intentional.
ssh_run() {
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$1"
}

# Probe: does the datastore already exist?
DS_EXISTS=0
if ssh_run "proxmox-backup-manager datastore list" 2>/dev/null | awk '{print $1}' | grep -qx "$DS_NAME"; then
  DS_EXISTS=1
fi

if (( DS_EXISTS )); then
  echo "[ok] datastore '$DS_NAME' already exists; will update prune-job only"
else
  # mkdir + datastore create
  echo "[..] creating datastore '$DS_NAME' at $DS_PATH"
  CMD_CREATE=(
    "mkdir -p '$DS_PATH/.chunks' &&"
    "proxmox-backup-manager datastore create '$DS_NAME' '$DS_PATH'"
  )
  CMD_STR="${CMD_CREATE[*]}"
  if (( EXECUTE )); then
    ssh_run "$CMD_STR"
  else
    echo "[dry-run] $CMD_STR"
  fi
fi

# Prune-job: update if exists, else create
PRUNE_NAME="${DS_NAME}-prune"
PRUNE_EXISTS=0
if ssh_run "proxmox-backup-manager prune-job list" 2>/dev/null | awk '{print $1}' | grep -qx "$PRUNE_NAME"; then
  PRUNE_EXISTS=1
fi

if (( PRUNE_EXISTS )); then
  CMD_UPDATE="proxmox-backup-manager prune-job update '$PRUNE_NAME' \
    --schedule '$PRUNE_RUN' \
    --keep-last $KEEP_LAST --keep-daily $KEEP_DAILY \
    --keep-weekly $KEEP_WEEKLY --keep-monthly $KEEP_MONTHLY"
  if (( EXECUTE )); then
    echo "[..] updating prune-job '$PRUNE_NAME'"
    ssh_run "$CMD_UPDATE"
  else
    echo "[dry-run] $CMD_UPDATE"
  fi
else
  CMD_NEW="proxmox-backup-manager prune-job create '$PRUNE_NAME' \
    --schedule '$PRUNE_RUN' --store '$DS_NAME' \
    --keep-last $KEEP_LAST --keep-daily $KEEP_DAILY \
    --keep-weekly $KEEP_WEEKLY --keep-monthly $KEEP_MONTHLY"
  if (( EXECUTE )); then
    echo "[..] creating prune-job '$PRUNE_NAME'"
    ssh_run "$CMD_NEW"
  else
    echo "[dry-run] $CMD_NEW"
  fi
fi

if (( ! EXECUTE )); then
  echo "[--] dry-run. Pass --execute to apply on $HOST." >&2
  exit 0
fi
echo "[ok] datastore '$DS_NAME' ready on $HOST"
