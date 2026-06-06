#!/usr/bin/env bash
# lab-health.sh
# Quick host + VM health check for a Proxmox node. Run via cron or on demand.
# Exits non-zero if any check fails (good for monitoring).

set -uo pipefail

WARN=()
FAIL=()

note() { printf "  %s\n" "$*"; }
warn() { WARN+=("$*"); printf "\e[33m[WARN]\e[0m %s\n" "$*"; }
bad()  { FAIL+=("$*"); printf "\e[31m[FAIL]\e[0m %s\n" "$*"; }
good() { printf "\e[32m[OK]\e[0m %s\n" "$*"; }

echo "===== $(hostname -s) - $(date -Is) ====="

# 1. Uptime / load
read -r up _ load1 load5 load15 < <(uptime | awk -F'[, ]+' '{print $4,$5,$10,$11,$12}')
cores=$(nproc)
note "Uptime $up days, load (1/5/15m): $load1 $load5 $load15 across $cores cores"
if (( $(echo "$load5 > $cores * 1.5" | bc -l) )); then
  warn "5-min load $load5 exceeds 1.5x core count ($cores)"
fi

# 2. RAM
mem_used_pct=$(free | awk '/Mem:/ {printf "%d", $3/$2*100}')
note "RAM used: ${mem_used_pct}%"
(( mem_used_pct > 90 )) && warn "RAM usage above 90%"

# 3. Disks
df -h --output=target,pcent | awk 'NR>1' | while read mnt pct; do
  num=${pct%\%}
  case "$mnt" in
    tmpfs|/dev/shm) continue ;;
    /dev|/run|/sys|/proc|"/") continue ;;
  esac
  if (( num >= 90 )); then
    echo "FAIL_DISK $mnt $pct"
  elif (( num >= 80 )); then
    echo "WARN_DISK $mnt $pct"
  fi
done | while read level mnt pct; do
  case "$level" in
    WARN_DISK) warn "Disk $mnt at $pct" ;;
    FAIL_DISK) bad "Disk $mnt at $pct" ;;
  esac
done

# 4. ZFS pools
if command -v zpool >/dev/null; then
  for p in $(zpool list -H -o name 2>/dev/null); do
    health=$(zpool list -H -o health "$p")
    cap=$(zpool list -H -o capacity "$p" | tr -d '%')
    note "zpool $p health=$health cap=${cap}%"
    [[ $health != ONLINE ]] && bad "zpool $p not ONLINE ($health)"
    (( cap >= 85 )) && warn "zpool $p capacity ${cap}%"
  done
fi

# 5. PVE cluster quorum
if command -v pvecm >/dev/null && pvecm status &>/dev/null; then
  if pvecm status | grep -q "Quorate:.*Yes"; then
    good "PVE cluster quorate"
  else
    bad "PVE cluster NOT quorate"
  fi
fi

# 6. VMs running vs configured
if command -v qm >/dev/null; then
  total=$(qm list | tail -n +2 | wc -l)
  running=$(qm list | awk 'NR>1 && $3=="running"' | wc -l)
  note "VMs: $running running / $total total"
  while read -r vmid status _; do
    [[ "$vmid" == "VMID" ]] && continue
    if [[ "$status" == "stopped" ]]; then
      onboot=$(qm config "$vmid" | awk -F: '/^onboot:/ {print $2}' | tr -d ' ')
      if [[ "$onboot" == "1" ]]; then
        warn "VM $vmid is stopped but onboot=1"
      fi
    fi
  done < <(qm list)
fi

# 7. Stale snapshots (auto-*) older than 14 days
if command -v qm >/dev/null; then
  threshold=$(date -d '14 days ago' +%s)
  for id in $(qm list | awk 'NR>1 {print $1}'); do
    while read -r line; do
      name=$(echo "$line" | awk '{print $2}')
      ts=$(echo "$line"   | awk '{print $4"T"$5}')
      [[ -z $ts ]] && continue
      epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
      (( epoch && epoch < threshold )) && warn "Stale snapshot vm=$id name=$name age=$(( ( $(date +%s) - epoch ) / 86400 ))d"
    done < <(qm listsnapshot "$id" 2>/dev/null | grep -E 'auto-')
  done
fi

# 8. Recent task failures (last 24h)
if command -v pvesh >/dev/null; then
  fails=$(pvesh get /cluster/tasks --output-format=json 2>/dev/null \
          | jq '[.[] | select(.status != "OK" and .status != null and (.endtime // 0) > (now - 86400))] | length')
  fails=${fails:-0}
  note "PVE failed tasks last 24h: $fails"
  (( fails > 0 )) && warn "$fails PVE tasks failed in the last 24h"
fi

echo "-----"
echo "Summary: ${#FAIL[@]} fail, ${#WARN[@]} warn"
if (( ${#FAIL[@]} > 0 )); then exit 2
elif (( ${#WARN[@]} > 0 )); then exit 1
else echo "All checks OK"; exit 0
fi
