#!/usr/bin/env python3
"""
labctl.py - The lab-in-a-box runner.

Reads lab.yaml, validates it, and dispatches commands to the right
hypervisor over SSH (Proxmox) or WinRM/PowerShell (Hyper-V).

Subcommands:
    validate      Parse and validate lab.yaml
    plan          Show intended changes (create/diff) for every VM
    apply         Create/update VMs in the lab
    inventory     Print current state of all VMs
    start         Power on VMs in start_order
    stop          Power off VMs in reverse start_order
    backup        Trigger hypervisor-specific backup of every VM
    drill         Walk the DR restore flow against a random VM

Requires:
    Python 3.8+, PyYAML, optionally: ssh (proxmox), pwsh (hyperv)

Usage:
    python3 scripts/python/labctl.py validate
    python3 scripts/python/labctl.py plan
    python3 scripts/python/labctl.py apply --hypervisor pve01
    python3 scripts/python/labctl.py start
    python3 scripts/python/labctl.py stop --vm web01
    python3 scripts/python/labctl.py backup
    python3 scripts/python/labctl.py drill --vm web01
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_LAB = REPO_ROOT / "lab.yaml"


# =============================================================================
# Data model
# =============================================================================
class LabError(Exception):
    pass


@dataclass
class Network:
    name: str
    vlan_id: int
    subnet: str
    gateway: str
    dhcp: bool


@dataclass
class Hypervisor:
    name: str
    type: str
    host: str
    extras: dict = field(default_factory=dict)


@dataclass
class VM:
    name: str
    hypervisor: str
    role: str
    network: str
    secondary_networks: list[str]
    cpu: int
    memory_mb: int
    disk_gb: int
    vmid: int | None
    iso: str | None
    ip: str | None
    start_order: int
    onboot: bool
    post_install: str | None
    domain: str | None
    domain_member: str | None
    notes: str

    @property
    def key(self) -> str:
        return f"{self.hypervisor}/{self.name}"


def load_lab(path: Path) -> tuple[dict, list[Network], list[Hypervisor], list[VM]]:
    if not path.exists():
        raise LabError(f"lab.yaml not found: {path}")
    with path.open() as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise LabError("lab.yaml is not a mapping at the top level")

    # Networks
    nets: list[Network] = []
    for n, cfg in (data.get("networks") or {}).items():
        nets.append(Network(
            name=n,
            vlan_id=int(cfg.get("vlan_id", 0)),
            subnet=cfg["subnet"],
            gateway=cfg["gateway"],
            dhcp=bool(cfg.get("dhcp", False)),
        ))

    # Hypervisors
    hvs: list[Hypervisor] = []
    for h, cfg in (data.get("hypervisors") or {}).items():
        hvs.append(Hypervisor(
            name=h,
            type=cfg["type"],
            host=cfg["host"],
            extras={k: v for k, v in cfg.items() if k not in ("type", "host")},
        ))

    # VMs
    vms: list[VM] = []
    for cfg in data.get("vms") or []:
        vms.append(VM(
            name=cfg["name"],
            hypervisor=cfg["hypervisor"],
            role=cfg.get("role", ""),
            network=cfg["network"],
            secondary_networks=list(cfg.get("secondary_networks") or []),
            cpu=int(cfg["cpu"]),
            memory_mb=int(cfg["memory_mb"]),
            disk_gb=int(cfg["disk_gb"]),
            vmid=int(cfg["vmid"]) if "vmid" in cfg else None,
            iso=cfg.get("iso"),
            ip=cfg.get("ip"),
            start_order=int(cfg["start_order"]),
            onboot=bool(cfg.get("onboot", False)),
            post_install=cfg.get("post_install"),
            domain=cfg.get("domain"),
            domain_member=cfg.get("domain_member"),
            notes=str(cfg.get("notes", "")).strip(),
        ))

    return data, nets, hvs, vms


def validate(data: dict, nets: list[Network], hvs: list[Hypervisor], vms: list[VM]) -> list[str]:
    errors: list[str] = []
    net_names = {n.name for n in nets}
    hv_names = {h.name for h in hvs}
    hv_types = {h.name: h.type for h in hvs}

    seen_names: set[str] = set()
    seen_vmids: dict[int, str] = {}

    for vm in vms:
        if vm.name in seen_names:
            errors.append(f"duplicate VM name: {vm.name}")
        seen_names.add(vm.name)

        if vm.hypervisor not in hv_names:
            errors.append(f"{vm.key}: unknown hypervisor '{vm.hypervisor}'")
        elif hv_types[vm.hypervisor] == "proxmox" and vm.vmid is None:
            errors.append(f"{vm.key}: proxmox VM missing 'vmid'")
        elif vm.vmid is not None:
            if vm.vmid in seen_vmids:
                errors.append(f"{vm.key}: duplicate vmid {vm.vmid} (also {seen_vmids[vm.vmid]})")
            seen_vmids[vm.vmid] = vm.key

        if vm.network not in net_names:
            errors.append(f"{vm.key}: unknown primary network '{vm.network}'")
        for s in vm.secondary_networks:
            if s not in net_names:
                errors.append(f"{vm.key}: unknown secondary network '{s}'")

        if not (1 <= vm.start_order <= 999):
            errors.append(f"{vm.key}: start_order must be 1-999, got {vm.start_order}")
        if vm.cpu < 1:
            errors.append(f"{vm.key}: cpu must be >= 1")
        if vm.memory_mb < 256:
            errors.append(f"{vm.key}: memory_mb must be >= 256")
        if vm.disk_gb < 10:
            errors.append(f"{vm.key}: disk_gb must be >= 10")

    return errors


# =============================================================================
# Per-hypervisor command generators
# =============================================================================
def proxmox_plan(vm: VM, hv: Hypervisor, nets: dict[str, Network]) -> list[str]:
    net = nets[vm.network]
    bridge = hv.extras.get("default_bridge", "vmbr0")
    storage = hv.extras.get("default_storage", "local-lvm")
    iso_storage = hv.extras.get("iso_storage", "local")

    lines: list[str] = []
    lines.append(f"# {vm.key}  role={vm.role}  vlan={net.vlan_id}")
    lines.append(f"qm create {vm.vmid} --name {vm.name} --memory {vm.memory_mb} --cores {vm.cpu} \\")
    lines.append(f"       --net0 virtio,bridge={bridge},tag={net.vlan_id} \\")
    lines.append(f"       --scsi0 {storage}:{vm.disk_gb} --scsihw virtio-scsi-single \\")
    lines.append("       --ostype l26 --agent enabled=1")
    if vm.iso:
        lines.append(f"qm set {vm.vmid} --ide2 {iso_storage}:iso/{vm.iso},media=cdrom")
        lines.append(f"qm set {vm.vmid} --boot order=ide2")
    if vm.onboot:
        lines.append(f"qm set {vm.vmid} --onboot 1")
    return lines


def hyperv_plan(vm: VM, hv: Hypervisor, nets: dict[str, Network]) -> list[str]:
    net = nets[vm.network]
    switch = hv.extras.get("default_switch", "vSwitch-Internal")
    vm_path = hv.extras.get("default_vm_path", "D:\\VMs")
    vhd_path = hv.extras.get("default_vhd_path", "D:\\VMs\\Virtual Hard Disks")

    lines: list[str] = []
    lines.append(f"# {vm.key}  role={vm.role}  vlan={net.vlan_id}")
    lines.append(f"New-VM -Name {vm.name} -Generation 2 \\")
    lines.append(f"     -MemoryStartupBytes {vm.memory_mb * 1024 * 1024} \\")
    lines.append(f"     -Path '{vm_path}' \\")
    lines.append(f"     -NewVHDPath '{vhd_path}\\{vm.name}\\{vm.name}.vhdx' \\")
    lines.append(f"     -NewVHDSizeBytes {vm.disk_gb * 1024 * 1024 * 1024} \\")
    lines.append(f"     -SwitchName '{switch}'")
    lines.append(f"Set-VMProcessor -VMName {vm.name} -Count {vm.cpu}")
    if vm.iso:
        lines.append(f"Add-VMDvdDrive -VMName {vm.name} -Path 'D:\\ISOs\\{vm.iso}'")
    if net.vlan_id:
        lines.append(f"Set-VMNetworkAdapterVlan -VMName {vm.name} -Access -VlanId {net.vlan_id}")
    return lines


def gen_plan(vms: list[VM], hvs: list[Hypervisor], nets: list[Network],
             only_hypervisor: str | None) -> list[str]:
    net_idx = {n.name: n for n in nets}
    hv_idx = {h.name: h for h in hvs}
    out: list[str] = []
    sorted_vms = sorted(vms, key=lambda v: (v.hypervisor, v.start_order, v.name))
    for vm in sorted_vms:
        if only_hypervisor and vm.hypervisor != only_hypervisor:
            continue
        hv = hv_idx.get(vm.hypervisor)
        if not hv:
            out.append(f"# SKIP {vm.key} - hypervisor not defined")
            continue
        if hv.type == "proxmox":
            out.extend(proxmox_plan(vm, hv, net_idx))
        elif hv.type == "hyperv":
            out.extend(hyperv_plan(vm, hv, net_idx))
        else:
            out.append(f"# SKIP {vm.key} - unsupported hypervisor type '{hv.type}'")
        out.append("")
    return out


# =============================================================================
# Subcommand implementations
# =============================================================================
def cmd_validate(args, _) -> int:
    try:
        data, nets, hvs, vms = load_lab(args.lab)
    except LabError as e:
        print(f"[FAIL] {e}", file=sys.stderr)
        return 2
    errors = validate(data, nets, hvs, vms)
    if errors:
        print(f"[FAIL] {len(errors)} validation error(s):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"[OK] lab.yaml is valid: {len(vms)} VMs across {len(hvs)} hypervisor(s)")
    return 0


def cmd_plan(args, _) -> int:
    data, nets, hvs, vms = load_lab(args.lab)
    errs = validate(data, nets, hvs, vms)
    if errs:
        print("[FAIL] validation errors:", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 1
    plan = gen_plan(vms, hvs, nets, args.hypervisor)
    print(f"# Plan for {len(vms)} VM(s) in lab '{data['lab'].get('name','?')}'")
    if args.hypervisor:
        print(f"# Filtered to hypervisor: {args.hypervisor}")
    print()
    for line in plan:
        print(line)
    return 0


def cmd_apply(args, _) -> int:
    # Dry-run only in v1.4 - we don't want to actually create VMs from CI.
    # Future: dispatch the commands from gen_plan() to the right hypervisor.
    print("[WARN] `apply` is dry-run only in v1.4.  Use `plan` to preview.", file=sys.stderr)
    return cmd_plan(args, _)


def cmd_inventory(args, _) -> int:
    data, nets, hvs, vms = load_lab(args.lab)
    print(f"# Lab '{data['lab'].get('name','?')}' - {len(vms)} VM(s)")
    print(f"{'Hypervisor':<12} {'Name':<22} {'Role':<22} {'VLAN':<5} {'CPU':<4} {'RAM(MB)':<8} {'Disk':<6} {'Order':<6} {'Onboot'}")
    for vm in sorted(vms, key=lambda v: (v.hypervisor, v.start_order)):
        net = next((n for n in nets if n.name == vm.network), None)
        vlan = str(net.vlan_id) if net else "?"
        print(f"{vm.hypervisor:<12} {vm.name:<22} {vm.role:<22} {vlan:<5} {vm.cpu:<4} {vm.memory_mb:<8} {vm.disk_gb:<6} {vm.start_order:<6} {vm.onboot}")
    return 0


def cmd_start(args, _) -> int:
    data, nets, hvs, vms = load_lab(args.lab)
    if args.vm:
        targets = [v for v in vms if v.name == args.vm]
    else:
        targets = sorted(vms, key=lambda v: v.start_order)
    for vm in targets:
        hv = next((h for h in hvs if h.name == vm.hypervisor), None)
        if hv is None:
            print(f"[SKIP] {vm.key} - no hypervisor definition")
            continue
        if hv.type == "proxmox":
            print(f"[pve] qm start {vm.vmid}    # {vm.name}")
        elif hv.type == "hyperv":
            print(f"[hvr] Start-VM -Name {vm.name}")
    return 0


def cmd_stop(args, _) -> int:
    data, nets, hvs, vms = load_lab(args.lab)
    if args.vm:
        targets = [v for v in vms if v.name == args.vm]
    else:
        targets = sorted(vms, key=lambda v: -v.start_order)
    for vm in targets:
        hv = next((h for h in hvs if h.name == vm.hypervisor), None)
        if hv is None:
            continue
        if hv.type == "proxmox":
            print(f"[pve] qm shutdown {vm.vmid}    # {vm.name}")
        elif hv.type == "hyperv":
            print(f"[hvr] Stop-VM -Name {vm.name} -Force:$false")
    return 0


def cmd_backup(args, _) -> int:
    print("# Per-hypervisor backup commands:")
    print("#   Proxmox : vzdump --all 1 --storage nas-backup --prune-backups keep-last=3,keep-daily=7,keep-weekly=4")
    print("#   Hyper-V : Backup-VMCheckpoints.ps1 -ExportPath E:\\Exports -RetainDays 7")
    print("# See scripts/bash/backup-all-vms.sh and hypervisors/hyper-v/scripts/Backup-VMCheckpoints.ps1")
    return 0


def cmd_drill(args, _) -> int:
    if not args.vm:
        print("--vm required for drill", file=sys.stderr)
        return 2
    print(f"# DR drill: walk the Scenario 2 runbook for VM '{args.vm}'")
    print("# 1. Identify last good backup")
    print("# 2. qmrestore / Restore-VMFromExport / VBoxManage import / robocopy")
    print("# 3. Re-attach vSwitch + VLAN")
    print("# 4. Power on")
    print("# 5. Smoke test (Get-Service / systemctl status / Test-NetConnection)")
    print("# 6. Log to snapshots-backup/recovery-drills.md")
    print()
    print("# Full procedure: docs/snapshots-backup/recovery-procedures.md#scenario-2")
    return 0


# =============================================================================
# Argument parsing
# =============================================================================
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lab", type=Path, default=DEFAULT_LAB,
                   help=f"Path to lab.yaml (default: {DEFAULT_LAB})")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("validate", help="Parse and validate lab.yaml").set_defaults(func=cmd_validate)

    sp = sub.add_parser("plan", help="Show intended create commands")
    sp.add_argument("--hypervisor", help="Filter to a single hypervisor")
    sp.set_defaults(func=cmd_plan)

    sp = sub.add_parser("apply", help="Create/update VMs in the lab (dry-run in v1.4)")
    sp.add_argument("--hypervisor", help="Filter to a single hypervisor")
    sp.set_defaults(func=cmd_apply)

    sub.add_parser("inventory", help="Print current state of all VMs").set_defaults(func=cmd_inventory)

    sp = sub.add_parser("start", help="Power on VMs in start order")
    sp.add_argument("--vm", help="Single VM name (default: all)")
    sp.set_defaults(func=cmd_start)

    sp = sub.add_parser("stop", help="Power off VMs in reverse start order")
    sp.add_argument("--vm", help="Single VM name (default: all)")
    sp.set_defaults(func=cmd_stop)

    sub.add_parser("backup", help="Show the backup commands for this lab").set_defaults(func=cmd_backup)

    sp = sub.add_parser("drill", help="Walk a DR drill for one VM")
    sp.add_argument("--vm", required=True, help="VM name")
    sp.set_defaults(func=cmd_drill)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args, parser)


if __name__ == "__main__":
    raise SystemExit(main())
