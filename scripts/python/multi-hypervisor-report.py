#!/usr/bin/env python3
"""
multi-hypervisor-report.py
Generate a unified, cross-hypervisor inventory report.

Reads CSV inputs produced by the per-hypervisor inventory tools:
  - scripts/powershell/Get-LabInventory.ps1  -> hyperv-*.csv
  - scripts/bash/vm-inventory.sh             -> proxmox-*.csv
  - (optional) VirtualBox / VMware exports

Outputs a single Markdown table summarizing the entire lab.

Usage:
    python3 multi-hypervisor-report.py \
        --hyperv reports/hyperv-20260131.csv \
        --proxmox reports/proxmox-20260131.csv \
        --out reports/lab-summary-20260131.md
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import sys
from pathlib import Path
from typing import Iterable


def read_hyperv(path: Path) -> Iterable[dict]:
    with path.open(newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            yield {
                "Host":   "Hyper-V",
                "Name":   row["Name"],
                "State":  row["State"],
                "vCPU":   row["vCPU"],
                "RAM_GB": row["StartupGB"],
                "Disk_GB": row["DiskUsedGB"],
                "Network": row["Switch"],
                "IP":     row["IPs"],
            }


def read_proxmox(path: Path) -> Iterable[dict]:
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            mem_mb = float(row.get("MemMB") or 0)
            yield {
                "Host":   f"Proxmox-{row['Kind']}",
                "Name":   row["Name"],
                "State":  row["Status"],
                "vCPU":   row["CPU"],
                "RAM_GB": f"{mem_mb/1024:.1f}",
                "Disk_GB": row.get("DiskGB", "?"),
                "Network": row.get("Bridges", ""),
                "IP":     row.get("IP", ""),
            }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--hyperv",   type=Path, help="CSV from Get-LabInventory.ps1")
    p.add_argument("--proxmox",  type=Path, help="CSV from vm-inventory.sh")
    p.add_argument("--out",      type=Path, default=Path("lab-summary.md"))
    args = p.parse_args()

    rows: list[dict] = []
    if args.hyperv:
        if not args.hyperv.exists(): sys.exit(f"Missing: {args.hyperv}")
        rows.extend(read_hyperv(args.hyperv))
    if args.proxmox:
        if not args.proxmox.exists(): sys.exit(f"Missing: {args.proxmox}")
        rows.extend(read_proxmox(args.proxmox))

    if not rows:
        sys.exit("No input data. Provide --hyperv and/or --proxmox.")

    rows.sort(key=lambda r: (r["Host"], r["Name"]))

    lines = [
        f"# Lab Inventory - {dt.date.today().isoformat()}",
        "",
        f"Total guests: **{len(rows)}**",
        "",
        "| Host | Name | State | vCPU | RAM (GB) | Disk (GB) | Network | IP |",
        "|------|------|-------|------|----------|-----------|---------|----|",
    ]
    for r in rows:
        lines.append(
            "| {Host} | {Name} | {State} | {vCPU} | {RAM_GB} | {Disk_GB} | {Network} | {IP} |".format(**r)
        )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[OK] Wrote {args.out} ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
