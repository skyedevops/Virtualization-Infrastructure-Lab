#!/usr/bin/env bash
# vm-inventory.sh
# Inventory KVM/Proxmox VMs and LXC containers; emit CSV to stdout or -o file.
#
# Usage:
#   ./vm-inventory.sh
#   ./vm-inventory.sh -o /tmp/inv.csv

set -euo pipefail

OUT=""
while getopts "o:h" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    h) echo "Usage: $0 [-o output.csv]"; exit 0 ;;
    *) echo "Unknown flag: -$OPTARG" >&2; exit 2 ;;
  esac
done

emit() {
  if [[ -n $OUT ]]; then echo "$1" >> "$OUT"; else echo "$1"; fi
}

[[ -n $OUT ]] && : > "$OUT"

emit "Kind,VMID,Name,Status,CPU,MemMB,DiskGB,Storage,Bridges,IP"

# KVM VMs
if command -v qm >/dev/null; then
  while read -r vmid name status mem _ disk _; do
    [[ "$vmid" == "VMID" ]] && continue
    cfg=$(qm config "$vmid")
    cpu=$(echo "$cfg" | awk -F: '/^cores:/ {print $2; exit}' | tr -d ' ')
    cpu=${cpu:-1}
    bridges=$(echo "$cfg" | awk -F'=' '/^net[0-9]+:/ {for(i=1;i<=NF;i++) if($i ~ /^bridge=/){sub("bridge=","",$i); split($i,a,","); print a[1]}}' | sort -u | paste -sd';' -)
    storage=$(echo "$cfg" | awk -F'=' '/^(scsi|virtio|sata|ide)[0-9]+:/ {sub(/^[a-z]+[0-9]+:[ ]*/,""); split($0,a,":"); print a[1]}' | sort -u | paste -sd';' -)
    diskgb=$(echo "$cfg" | awk -F'=' '/^(scsi|virtio|sata|ide)[0-9]+:/ {for(i=1;i<=NF;i++) if($i ~ /size=/){sub("size=","",$i); split($i,a,","); print a[1]}}' | head -1)
    ip=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null \
         | grep -oE '"ip-address": "[0-9.]+"' \
         | grep -v '"127\.' \
         | head -1 | cut -d'"' -f4)
    emit "qm,$vmid,$name,$status,$cpu,$mem,${diskgb:-?},$storage,$bridges,${ip:-}"
  done < <(qm list)
fi

# LXC CTs
if command -v pct >/dev/null; then
  while read -r vmid name status mem _ disk; do
    [[ "$vmid" == "VMID" ]] && continue
    cfg=$(pct config "$vmid")
    cpu=$(echo "$cfg" | awk -F: '/^cores:/ {print $2; exit}' | tr -d ' ')
    cpu=${cpu:-1}
    bridges=$(echo "$cfg" | awk -F'=' '/^net[0-9]+:/ {for(i=1;i<=NF;i++) if($i ~ /bridge=/){sub("bridge=","",$i); split($i,a,","); print a[1]}}' | sort -u | paste -sd';' -)
    ip=$(echo "$cfg" | awk -F'=' '/^net[0-9]+:/ {for(i=1;i<=NF;i++) if($i ~ /ip=/){sub("ip=","",$i); split($i,a,","); print a[1]}}' | head -1)
    emit "pct,$vmid,$name,$status,$cpu,$mem,$disk,local,$bridges,${ip:-}"
  done < <(pct list)
fi

[[ -n $OUT ]] && echo "[OK] Wrote $OUT" >&2
