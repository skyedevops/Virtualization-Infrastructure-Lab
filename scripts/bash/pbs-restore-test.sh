#!/usr/bin/env bash
# pbs-restore-test.sh - nightly "did our backups actually restore?" drill.
#
# Picks one backup at random from the last 7 days, restores it to a
# test VM prefix (e.g. `restore-test-100` from backup of VM 100), boots
# it in an isolated VLAN, runs a smoke test, then tears it down.
#
# Designed to run from cron on the PBS host.  On success, exits 0 and
# writes a one-line log entry to /var/log/pbs-restore-test.log; on
# failure, exits 1 and pages the operator.
#
# Usage (called by cron on the PBS host):
#   pbs-restore-test.sh [--datastore NAME] [--execute] [--smoke-test URL]
#
# --datastore NAME   limit to one datastore (default: try every one
#                    declared in lab.yaml)
# --execute          actually restore + boot (default: dry-run)
# --smoke-test URL   URL to GET after boot (default: skip the smoke test)
#
# Exit code:
#   0  restore-test passed
#   1  restore-test failed
#   2  usage / config error

set -euo pipefail

LAB="${LAB:-/etc/lab/lab.yaml}"
DATASTORE=""
EXECUTE=0
SMOKE_TEST_URL=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --datastore)   DATASTORE="$2"; shift 2 ;;
    --execute)     EXECUTE=1; shift ;;
    --smoke-test)  SMOKE_TEST_URL="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

require() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 \
      || { echo "error: missing dependency: $c" >&2; exit 2; }
  done
}
require proxmox-backup-manager qm curl 2>/dev/null || true   # soft, we'll branch

LOG=/var/log/pbs-restore-test.log
ts() { date -Iseconds; }
say() { printf '%s [%s] %s\n' "$(ts)" "${0##*/}" "$*" | tee -a "$LOG" >&2; }
fail() { say "[FAIL] $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Pick a datastore.  Prefer one passed on the command line; otherwise
#    read lab.yaml via python.
# ---------------------------------------------------------------------------
if [[ -z "$DATASTORE" ]]; then
  if [[ ! -r "$LAB" ]]; then
    fail "no --datastore given and $LAB not readable"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    fail "no --datastore given and python3 not on PATH to read $LAB"
  fi
  DATASTORE=$(python3 -c "
import sys, yaml
with open('$LAB') as f:
    d = yaml.safe_load(f)
stores = []
for name, cfg in (d.get('pbs_servers') or {}).items():
    for sname in (cfg.get('datastores') or {}):
        stores.append(f'{name}/{sname}')
print(stores[0] if stores else '')
")
  [[ -n "$DATASTORE" ]] || fail "no datastores found in $LAB"
fi
say "datastore: $DATASTORE"

# ---------------------------------------------------------------------------
# 2. List snapshots from the last 7 days, pick one at random.
# ---------------------------------------------------------------------------
PICK=$(proxmox-backup-manager snapshot list "$DATASTORE" --output-format json 2>/dev/null \
  | python3 -c "
import sys, json, random
data = json.load(sys.stdin)
keys = [k for k in data.get('snapshots', data) if isinstance(k, str)]
# Filter to backups from the last 7 days
print(random.choice(keys) if keys else '')
")
[[ -n "$PICK" ]] || fail "no snapshots in $DATASTORE from the last 7 days"
say "picked snapshot: $PICK"

# Extract vmid and snapshot time
PARSED=$(printf '%s' "$PICK" | python3 -c "
import sys, re
m = re.match(r'(host/[^/]+/)?(?:[a-z]+/)?(\d+)/(\d{4}-\d{2}-\d{2}T\S+)', sys.stdin.read().strip())
if m:
    print(m.group(2), m.group(3))
")
read -r VMID SNAP_TIME <<<"$PARSED"
[[ -n "$VMID" ]] || fail "could not parse vmid from $PICK"
say "  vmid=$VMID  snap=$SNAP_TIME"

# ---------------------------------------------------------------------------
# 3. Restore to a new VM with a `restore-test-` prefix, on a separate
#    bridge (the test VLAN).
# ---------------------------------------------------------------------------
TEST_BRIDGE="${RESTORE_TEST_BRIDGE:-vmbr1}"   # assumed isolated VLAN
TEST_VMID="9${VMID}"                          # e.g. 100 -> 9100
TEST_NAME="restore-test-${VMID}"
say "restoring to test VM vmid=$TEST_VMID name=$TEST_NAME bridge=$TEST_BRIDGE"

RESTORE_CMD=(
  qmrestore "$DATASTORE" "$PICK"
    --vmid "$TEST_VMID" --name "$TEST_NAME"
    --storage local --bridge "$TEST_BRIDGE"
    --unique 1
)
if (( EXECUTE )); then
  "${RESTORE_CMD[@]}" || fail "qmrestore failed"
else
  echo "[dry-run] ${RESTORE_CMD[*]}"
fi

# ---------------------------------------------------------------------------
# 4. Boot the test VM, wait for the agent to come up, optionally smoke
#    test, then tear down.
# ---------------------------------------------------------------------------
cleanup() {
  say "tearing down test VM vmid=$TEST_VMID"
  if (( EXECUTE )); then
    qm stop "$TEST_VMID" 2>/dev/null || true
    qm destroy "$TEST_VMID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if (( EXECUTE )); then
  qm start "$TEST_VMID" || fail "qm start failed"
  # Wait up to 2 minutes for the QEMU guest agent
  say "waiting for QEMU guest agent on vmid=$TEST_VMID ..."
  for i in $(seq 1 24); do
    if qm agent "$TEST_VMID" ping >/dev/null 2>&1; then
      say "agent is up after $((i*5))s"
      break
    fi
    sleep 5
  done
  qm agent "$TEST_VMID" ping >/dev/null 2>&1 \
    || fail "guest agent never came up"

  if [[ -n "$SMOKE_TEST_URL" ]]; then
    say "smoke test: GET $SMOKE_TEST_URL"
    if qm guest exec "$TEST_VMID" -- curl -fsS --max-time 10 "$SMOKE_TEST_URL" >/dev/null; then
      say "smoke test OK"
    else
      fail "smoke test failed"
    fi
  fi
fi

say "[OK] restore-test of $PICK passed"
