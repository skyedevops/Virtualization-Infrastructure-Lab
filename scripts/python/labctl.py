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
import os
import shlex
import subprocess
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
    # v2.0 - cluster-aware fields
    storage: str | None = None       # logical storage id (must exist in cluster.storage[].id)
    ha: bool = False                 # call ha-manager add during apply
    ha_group: str | None = None      # name of the ha-group in the cluster

    @property
    def key(self) -> str:
        return f"{self.hypervisor}/{self.name}"


@dataclass
class Storage:
    """A shared storage definition inside a Proxmox cluster."""
    id: str
    type: str          # rbd | nfs | local | dir | ...
    content: str       # comma-separated PVE content list
    pool: str = ""     # for type=rbd
    server: str = ""   # for type=nfs
    export: str = ""   # for type=nfs


@dataclass
class HAGroup:
    """A `ha-group` definition inside a Proxmox cluster."""
    name: str
    nodes: list[str]
    restricted: bool = False
    nofailback: bool = False


@dataclass
class Cluster:
    """A Proxmox cluster: a set of hypervisors + shared storage + HA groups."""
    name: str
    type: str                                  # proxmox
    hypervisors: list[str]                     # keys in lab.hypervisors
    storage: dict[str, Storage] = field(default_factory=dict)   # id -> Storage
    ha_groups: dict[str, HAGroup] = field(default_factory=dict)  # name -> HAGroup

    def storage_for_vm(self, vm: VM) -> Storage | None:
        """Return the Storage record for a VM, falling back to local-lvm."""
        sid = vm.storage
        if sid is None:
            return None
        return self.storage.get(sid)


def load_lab(path: Path) -> tuple[dict, list[Network], list[Hypervisor], list[VM], list[Cluster]]:
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

    # Clusters (v2.0)
    clusters: list[Cluster] = []
    for cname, ccfg in (data.get("clusters") or {}).items():
        storage: dict[str, Storage] = {}
        for s in ccfg.get("storage") or []:
            sid = s["id"]
            storage[sid] = Storage(
                id=sid,
                type=s.get("type", "dir"),
                content=s.get("content", ""),
                pool=s.get("pool", ""),
                server=s.get("server", ""),
                export=s.get("export", ""),
            )
        ha_groups: dict[str, HAGroup] = {}
        for gname, g in (ccfg.get("ha_groups") or {}).items():
            ha_groups[gname] = HAGroup(
                name=gname,
                nodes=list(g.get("nodes") or []),
                restricted=bool(g.get("restricted", False)),
                nofailback=bool(g.get("nofailback", False)),
            )
        clusters.append(Cluster(
            name=cname,
            type=ccfg.get("type", "proxmox"),
            hypervisors=list(ccfg.get("hypervisors") or []),
            storage=storage,
            ha_groups=ha_groups,
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
            storage=cfg.get("storage"),
            ha=bool(cfg.get("ha", False)),
            ha_group=cfg.get("ha_group"),
        ))

    return data, nets, hvs, vms, clusters


def cluster_for_hv(clusters: list[Cluster], hv_name: str) -> Cluster | None:
    """Return the cluster a hypervisor belongs to, or None."""
    for c in clusters:
        if hv_name in c.hypervisors:
            return c
    return None


def validate(data: dict, nets: list[Network], hvs: list[Hypervisor],
              vms: list[VM], clusters: list[Cluster] | None = None) -> list[str]:
    errors: list[str] = []
    net_names = {n.name for n in nets}
    hv_names = {h.name for h in hvs}
    hv_types = {h.name: h.type for h in hvs}
    clusters = clusters or []

    # Cluster-level checks
    seen_cluster_names: set[str] = set()
    for c in clusters:
        if c.name in seen_cluster_names:
            errors.append(f"duplicate cluster name: {c.name}")
        seen_cluster_names.add(c.name)
        for hv in c.hypervisors:
            if hv not in hv_names:
                errors.append(f"cluster '{c.name}': unknown hypervisor '{hv}'")
            elif hv_types[hv] != c.type:
                errors.append(f"cluster '{c.name}': hypervisor '{hv}' is type "
                              f"'{hv_types[hv]}', cluster expects '{c.type}'")
        for sid in c.storage:
            if not sid:
                errors.append(f"cluster '{c.name}': storage entry missing 'id'")
        for gname, g in c.ha_groups.items():
            for hv in g.nodes:
                if hv not in c.hypervisors:
                    errors.append(f"cluster '{c.name}': ha-group '{gname}' "
                                  f"references non-member hypervisor '{hv}'")

    # Index: which cluster owns each hypervisor
    cluster_for: dict[str, Cluster] = {}
    for c in clusters:
        for hv in c.hypervisors:
            cluster_for[hv] = c

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

        # v2.0 cluster checks
        if vm.ha and vm.hypervisor in cluster_for:
            c = cluster_for[vm.hypervisor]
            if c.type != "proxmox":
                errors.append(f"{vm.key}: ha: true requires a proxmox cluster")
        elif vm.ha and vm.hypervisor not in cluster_for:
            errors.append(f"{vm.key}: ha: true requires a cluster for '{vm.hypervisor}'")
        if vm.ha_group and vm.hypervisor in cluster_for:
            c = cluster_for[vm.hypervisor]
            if vm.ha_group not in c.ha_groups:
                errors.append(f"{vm.key}: ha_group '{vm.ha_group}' not defined "
                              f"in cluster '{c.name}'")
        if vm.storage and vm.hypervisor in cluster_for:
            c = cluster_for[vm.hypervisor]
            if vm.storage not in c.storage:
                errors.append(f"{vm.key}: storage '{vm.storage}' not defined "
                              f"in cluster '{c.name}'")

    return errors


# =============================================================================
# Per-hypervisor command generators
# =============================================================================
def proxmox_plan(vm: VM, hv: Hypervisor, nets: dict[str, Network],
                 cluster: Cluster | None = None) -> list[str]:
    net = nets[vm.network]
    bridge = hv.extras.get("default_bridge", "vmbr0")
    storage = hv.extras.get("default_storage", "local-lvm")
    iso_storage = hv.extras.get("iso_storage", "local")
    # If the VM names a cluster storage, prefer it; otherwise use the
    # hypervisor default.  Cluster storage IDs (ceph-rbd, nfs-vm, etc.)
    # map directly to PVE storage names.
    if vm.storage and cluster and vm.storage in cluster.storage:
        disk_storage = vm.storage
    else:
        disk_storage = storage
    # ISO storage: if the cluster has an `iso` content storage, use it
    iso_target = iso_storage
    if cluster:
        for sid, s in cluster.storage.items():
            if "iso" in s.content and not vm.iso:
                continue
            if "iso" in s.content and vm.iso:
                iso_target = sid
                break

    lines: list[str] = []
    cluster_tag = f"  cluster={cluster.name}" if cluster else ""
    ha_tag = f"  ha={vm.ha_group or 'default'}" if vm.ha else ""
    lines.append(f"# {vm.key}  role={vm.role}  vlan={net.vlan_id}  "
                 f"storage={disk_storage}{cluster_tag}{ha_tag}")
    lines.append(f"qm create {vm.vmid} --name {vm.name} --memory {vm.memory_mb} --cores {vm.cpu} \\")
    lines.append(f"       --net0 virtio,bridge={bridge},tag={net.vlan_id} \\")
    lines.append(f"       --scsi0 {disk_storage}:{vm.disk_gb} --scsihw virtio-scsi-single \\")
    lines.append("       --ostype l26 --agent enabled=1")
    if vm.iso:
        lines.append(f"qm set {vm.vmid} --ide2 {iso_target}:iso/{vm.iso},media=cdrom")
        lines.append(f"qm set {vm.vmid} --boot order=ide2")
    if vm.onboot:
        lines.append(f"qm set {vm.vmid} --onboot 1")
    if vm.ha:
        ha_group = vm.ha_group or "default"
        lines.append(f"ha-manager add vm:{vm.vmid} --group {ha_group} --max_relocate 2")
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
             only_hypervisor: str | None,
             clusters: list[Cluster] | None = None) -> list[str]:
    net_idx = {n.name: n for n in nets}
    hv_idx = {h.name: h for h in hvs}
    clusters = clusters or []
    cluster_for = {hv: c for c in clusters for hv in c.hypervisors}
    out: list[str] = []
    sorted_vms = sorted(vms, key=lambda v: (v.hypervisor, v.start_order, v.name))
    for vm in sorted_vms:
        if only_hypervisor and vm.hypervisor != only_hypervisor:
            continue
        hv = hv_idx.get(vm.hypervisor)
        if not hv:
            out.append(f"# SKIP {vm.key} - hypervisor not defined")
            continue
        cluster = cluster_for.get(hv.name)
        if hv.type == "proxmox":
            out.extend(proxmox_plan(vm, hv, net_idx, cluster))
        elif hv.type == "hyperv":
            out.extend(hyperv_plan(vm, hv, net_idx))
        else:
            out.append(f"# SKIP {vm.key} - unsupported hypervisor type '{hv.type}'")
        out.append("")
    return out


def gen_create_commands(vm: VM, hv: Hypervisor, nets: dict[str, Network],
                        cluster: Cluster | None = None) -> list[str]:
    """Return the per-hypervisor shell commands that provision this VM.

    These are the actual commands to run over the transport, not the
    pretty-printed 'plan' output.
    """
    net = nets[vm.network]
    if hv.type == "proxmox":
        bridge = hv.extras.get("default_bridge", "vmbr0")
        storage = hv.extras.get("default_storage", "local-lvm")
        iso_storage = hv.extras.get("iso_storage", "local")
        # Resolve disk storage: cluster storage takes priority over default.
        if vm.storage and cluster and vm.storage in cluster.storage:
            disk_storage = vm.storage
        else:
            disk_storage = storage
        # ISO storage: pick a cluster storage that has 'iso' in content.
        iso_target = iso_storage
        if cluster and vm.iso:
            for sid, s in cluster.storage.items():
                if "iso" in s.content:
                    iso_target = sid
                    break
        cmds = [
            f"qm create {vm.vmid} --name {vm.name} --memory {vm.memory_mb} --cores {vm.cpu} "
            f"--net0 virtio,bridge={bridge},tag={net.vlan_id} "
            f"--scsi0 {disk_storage}:{vm.disk_gb} --scsihw virtio-scsi-single "
            f"--ostype l26 --agent enabled=1",
        ]
        if vm.iso:
            cmds += [
                f"qm set {vm.vmid} --ide2 {iso_target}:iso/{vm.iso},media=cdrom",
                f"qm set {vm.vmid} --boot order=ide2",
            ]
        if vm.onboot:
            cmds.append(f"qm set {vm.vmid} --onboot 1")
        if vm.ha:
            ha_group = vm.ha_group or "default"
            cmds.append(f"ha-manager add vm:{vm.vmid} --group {ha_group} --max_relocate 2")
        return cmds

    if hv.type == "hyperv":
        switch = hv.extras.get("default_switch", "vSwitch-Internal")
        vm_path = hv.extras.get("default_vm_path", "D:\\VMs")
        vhd_path = hv.extras.get("default_vhd_path", "D:\\VMs\\Virtual Hard Disks")
        vhdx = f"{vhd_path}\\{vm.name}\\{vm.name}.vhdx"
        # These are PowerShell; the HyperVTransport wraps them in pwsh -Command
        ps = [
            "$ErrorActionPreference='Stop';",
            f"New-Item -ItemType Directory -Path '{vhd_path}\\{vm.name}' -Force | Out-Null;",
            f"New-VM -Name '{vm.name}' -Generation 2 "
            f"-MemoryStartupBytes {vm.memory_mb * 1024 * 1024} "
            f"-Path '{vm_path}' "
            f"-NewVHDPath '{vhdx}' "
            f"-NewVHDSizeBytes {vm.disk_gb * 1024 * 1024 * 1024} "
            f"-SwitchName '{switch}';",
            f"Set-VMProcessor -VMName '{vm.name}' -Count {vm.cpu};",
        ]
        if vm.iso:
            ps.append(f"Add-VMDvdDrive -VMName '{vm.name}' -Path 'D:\\ISOs\\{vm.iso}';")
        if net.vlan_id:
            ps.append(f"Set-VMNetworkAdapterVlan -VMName '{vm.name}' -Access -VlanId {net.vlan_id};")
        return ps

    return []


# =============================================================================
# Transport layer
# =============================================================================
@dataclass
class CommandResult:
    host: str
    cmd: str
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


class Transport:
    """Base class for hypervisor transports."""

    def name(self) -> str:
        raise NotImplementedError

    def run(self, hv: Hypervisor, command: str) -> CommandResult:
        raise NotImplementedError


class SshTransport(Transport):
    """Subprocess + ssh. No third-party Python deps."""

    def name(self) -> str:
        return "ssh"

    def run(self, hv: Hypervisor, command: str) -> CommandResult:
        ssh_user = hv.extras.get("ssh_user", "root")
        ssh_key = hv.extras.get("ssh_key")
        port = str(hv.extras.get("ssh_port", "22"))
        opts = hv.extras.get("ssh_options", "")

        ssh_args = [
            "ssh",
            "-p", port,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
        ]
        if ssh_key:
            ssh_args += ["-i", os.fspath(Path(ssh_key).expanduser())]
        if opts:
            ssh_args += shlex.split(opts)
        ssh_args += [f"{ssh_user}@{hv.host}", "--", command]

        try:
            cp = subprocess.run(
                ssh_args,
                capture_output=True,
                text=True,
                timeout=hv.extras.get("timeout", 60),
            )
            return CommandResult(
                host=hv.host,
                cmd=command,
                returncode=cp.returncode,
                stdout=cp.stdout,
                stderr=cp.stderr,
            )
        except FileNotFoundError:
            return CommandResult(hv.host, command, 127, "", "ssh: command not found on PATH")
        except subprocess.TimeoutExpired:
            return CommandResult(hv.host, command, 124, "", "ssh: timeout")
        except Exception as e:  # pragma: no cover
            return CommandResult(hv.host, command, 1, "", f"ssh: {e}")


class LocalTransport(Transport):
    """Run commands locally - used for 'apply' on the same host as the runner
    (e.g. workstation running Proxmox in a nested setup) and for testing."""

    def name(self) -> str:
        return "local"

    def run(self, hv: Hypervisor, command: str) -> CommandResult:
        try:
            cp = subprocess.run(
                command, shell=True,
                capture_output=True, text=True, timeout=hv.extras.get("timeout", 60),
            )
            return CommandResult(hv.host, command, cp.returncode, cp.stdout, cp.stderr)
        except subprocess.TimeoutExpired:
            return CommandResult(hv.host, command, 124, "", "local: timeout")
        except Exception as e:  # pragma: no cover
            return CommandResult(hv.host, command, 1, "", f"local: {e}")


class HyperVTransport(Transport):
    """Run PowerShell on the Hyper-V host. Uses 'pwsh -Command'.

    If `win_user` is set, uses PowerShell Remoting (WinRM) via
    Invoke-Command; otherwise runs locally on the runner (when the
    runner is co-located with the Hyper-V host).
    """

    def name(self) -> str:
        return "hyperv-pwsh"

    def run(self, hv: Hypervisor, command: str) -> CommandResult:
        win_user = hv.extras.get("win_user")
        use_remoting = bool(win_user)

        # Wrap the user's PowerShell snippet (which already sets
        # $ErrorActionPreference and uses ;-separated statements) in
        # either a local pwsh call or a WinRM Invoke-Command call.
        if use_remoting:
            ps = (
                f"Invoke-Command -ComputerName {shlex.quote(hv.host)} "
                f"-ErrorAction Stop -ScriptBlock {{ {command} }}"
            )
        else:
            ps = command

        pwsh = hv.extras.get("pwsh_path", "pwsh")
        try:
            cp = subprocess.run(
                [pwsh, "-NoProfile", "-NonInteractive", "-Command", ps],
                capture_output=True, text=True,
                timeout=hv.extras.get("timeout", 60),
            )
            return CommandResult(hv.host, command, cp.returncode, cp.stdout, cp.stderr)
        except FileNotFoundError:
            return CommandResult(hv.host, command, 127, "", f"{pwsh}: command not found on PATH")
        except subprocess.TimeoutExpired:
            return CommandResult(hv.host, command, 124, "", "pwsh: timeout")
        except Exception as e:  # pragma: no cover
            return CommandResult(hv.host, command, 1, "", f"pwsh: {e}")


def make_transport(hv: Hypervisor) -> Transport:
    """Pick the right transport based on the hypervisor config.

    If `transport: ssh` is set, use SSH.
    If `transport: local` is set, run commands on this machine (no SSH).
    If `transport: hyperv` is set, use pwsh (local or WinRM).
    If unset: defaults to ssh for proxmox, hyperv for hyperv.
    """
    choice = hv.extras.get("transport")
    if choice is None:
        choice = "hyperv" if hv.type == "hyperv" else "ssh"
    choice = choice.lower()
    if choice == "ssh":
        return SshTransport()
    if choice == "local":
        return LocalTransport()
    if choice == "hyperv":
        return HyperVTransport()
    raise LabError(f"Unknown transport '{choice}' for hypervisor {hv.name}")


# =============================================================================
# Subcommand implementations
# =============================================================================
def cmd_validate(args, _) -> int:
    try:
        data, nets, hvs, vms, clusters = load_lab(args.lab)
    except LabError as e:
        print(f"[FAIL] {e}", file=sys.stderr)
        return 2
    errors = validate(data, nets, hvs, vms, clusters)
    if errors:
        print(f"[FAIL] {len(errors)} validation error(s):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"[OK] lab.yaml is valid: {len(vms)} VMs across {len(hvs)} hypervisor(s)"
          + (f", {len(clusters)} cluster(s)" if clusters else ""))
    return 0


def cmd_plan(args, _) -> int:
    data, nets, hvs, vms, clusters = load_lab(args.lab)
    errs = validate(data, nets, hvs, vms, clusters)
    if errs:
        print("[FAIL] validation errors:", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 1
    plan = gen_plan(vms, hvs, nets, args.hypervisor, clusters)
    print(f"# Plan for {len(vms)} VM(s) in lab '{data['lab'].get('name','?')}'")
    if args.hypervisor:
        print(f"# Filtered to hypervisor: {args.hypervisor}")
    print()
    for line in plan:
        print(line)
    return 0


def cmd_apply(args, _) -> int:
    """Actually provision VMs in the lab.

    Safety:
      - Always prints the plan first.
      - Refuses to run unless --execute is passed AND --yes is passed.
      - Stops on the first failure unless --keep-going.
    """
    data, nets, hvs, vms, clusters = load_lab(args.lab)
    errs = validate(data, nets, hvs, vms, clusters)
    if errs:
        print("[FAIL] validation errors:", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 1

    net_idx = {n.name: n for n in nets}
    hv_idx = {h.name: h for h in hvs}

    targets = [v for v in vms if not args.hypervisor or v.hypervisor == args.hypervisor]
    targets.sort(key=lambda v: (v.hypervisor, v.start_order, v.name))

    print(f"# Apply plan: {len(targets)} VM(s)")
    plan = gen_plan(vms, hvs, nets, args.hypervisor, clusters)
    for line in plan:
        print(line)

    if not args.execute:
        print("[--] dry-run (no changes). Pass --execute --yes to apply.", file=sys.stderr)
        return 0

    if not args.yes:
        try:
            ans = input("Apply these changes? [y/N] ").strip().lower()
        except EOFError:
            ans = "n"
        if ans not in ("y", "yes"):
            print("Aborted.")
            return 1

    # Execute
    failed = 0
    cluster_for = {hv: c for c in clusters for hv in c.hypervisors}
    for vm in targets:
        hv = hv_idx.get(vm.hypervisor)
        if hv is None:
            print(f"[SKIP] {vm.key} - no hypervisor definition")
            continue
        cluster = cluster_for.get(hv.name)
        try:
            cmds = gen_create_commands(vm, hv, net_idx, cluster)
        except Exception as e:
            print(f"[FAIL] {vm.key} - command generation error: {e}")
            failed += 1
            if not args.keep_going:
                break
            continue

        if not cmds:
            print(f"[SKIP] {vm.key} - no commands for hypervisor type '{hv.type}'")
            continue

        transport = make_transport(hv)
        print(f"\n>>> {vm.key}  (transport={transport.name()})")
        for cmd in cmds:
            print(f"  $ {cmd[:200]}{'...' if len(cmd) > 200 else ''}")
            result = transport.run(hv, cmd)
            if result.stderr.strip():
                print(f"    stderr: {result.stderr.strip()[:500]}")
            if not result.ok:
                print(f"  [FAIL] rc={result.returncode}")
                failed += 1
                if not args.keep_going:
                    print("[ABORT] stopping on first failure (use --keep-going to continue)")
                    return 1
            else:
                print("  [OK]")

    if failed:
        print(f"\n[FAIL] {failed} command(s) failed.")
        return 1
    print("\n[OK] apply complete.")
    return 0


def cmd_inventory(args, _) -> int:
    data, nets, hvs, vms, clusters = load_lab(args.lab)
    print(f"# Lab '{data['lab'].get('name','?')}' - {len(vms)} VM(s)")
    print(f"{'Hypervisor':<12} {'Name':<22} {'Role':<22} {'VLAN':<5} {'CPU':<4} {'RAM(MB)':<8} {'Disk':<6} {'Order':<6} {'Onboot'}")
    for vm in sorted(vms, key=lambda v: (v.hypervisor, v.start_order)):
        net = next((n for n in nets if n.name == vm.network), None)
        vlan = str(net.vlan_id) if net else "?"
        print(f"{vm.hypervisor:<12} {vm.name:<22} {vm.role:<22} {vlan:<5} {vm.cpu:<4} {vm.memory_mb:<8} {vm.disk_gb:<6} {vm.start_order:<6} {vm.onboot}")
    return 0


def cmd_start(args, _) -> int:
    data, nets, hvs, vms, clusters = load_lab(args.lab)
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
    data, nets, hvs, vms, clusters = load_lab(args.lab)
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
# v2.0 cluster subcommands
# =============================================================================
def _find_cluster_for(hv_name: str, clusters: list[Cluster]) -> Cluster | None:
    for c in clusters:
        if hv_name in c.hypervisors:
            return c
    return None


def _find_hv(name: str, hvs: list[Hypervisor]) -> Hypervisor | None:
    for h in hvs:
        if h.name == name:
            return h
    return None


def _run_on(hv: Hypervisor, command: str) -> CommandResult:
    return make_transport(hv).run(hv, command)


def cmd_migrate(args, _) -> int:
    """Live-migrate a VM to another node in its Proxmox cluster.

    Dry-run by default; pass --execute to actually migrate.
    """
    try:
        data, nets, hvs, vms, clusters = load_lab(args.lab)
    except LabError as e:
        print(f"[FAIL] {e}", file=sys.stderr)
        return 2

    vm = next((v for v in vms if v.name == args.vm), None)
    if vm is None:
        print(f"[FAIL] unknown VM '{args.vm}'", file=sys.stderr)
        return 1
    src_hv = _find_hv(vm.hypervisor, hvs)
    if src_hv is None or src_hv.type != "proxmox":
        print(f"[FAIL] VM '{args.vm}' is not on a Proxmox hypervisor", file=sys.stderr)
        return 1
    cluster = _find_cluster_for(src_hv.name, clusters)
    if cluster is None:
        print(f"[FAIL] hypervisor '{src_hv.name}' is not in any cluster", file=sys.stderr)
        return 1
    if args.target not in cluster.hypervisors:
        print(f"[FAIL] target '{args.target}' not in cluster '{cluster.name}'", file=sys.stderr)
        return 1
    if args.target == src_hv.name:
        print(f"[FAIL] target == source ({src_hv.name}); nothing to do", file=sys.stderr)
        return 1

    mode = args.mode or "online"
    cmd = f"qm migrate {vm.vmid} {args.target} {mode}"
    print("# Migration plan:")
    print(f"#   VM        : {vm.name} (vmid={vm.vmid})")
    print(f"#   source    : {src_hv.name} ({src_hv.host})")
    print(f"#   target    : {args.target}")
    print(f"#   mode      : {mode}")
    print(f"#   cluster   : {cluster.name}")
    print(f"#   command   : {cmd}")
    if not args.execute:
        print("[--] dry-run. Pass --execute to migrate.", file=sys.stderr)
        return 0
    print(f"[..] running: {cmd}")
    res = _run_on(src_hv, cmd)
    if res.stdout:
        print(res.stdout, end="")
    if res.stderr:
        print(res.stderr, end="", file=sys.stderr)
    if res.returncode != 0:
        print(f"[FAIL] qm migrate exited with {res.returncode}", file=sys.stderr)
        return 1
    print(f"[OK] {vm.name} migrated {src_hv.name} -> {args.target}")
    return 0


def cmd_ha_status(args, _) -> int:
    """Show HA status for every Proxmox cluster in the lab."""
    try:
        data, nets, hvs, vms, clusters = load_lab(args.lab)
    except LabError as e:
        print(f"[FAIL] {e}", file=sys.stderr)
        return 2
    if not clusters:
        print("[INFO] no clusters defined in lab.yaml", file=sys.stderr)
        return 0
    rc = 0
    for cluster in clusters:
        print(f"# Cluster: {cluster.name}  ({len(cluster.hypervisors)} nodes, "
              f"{len(cluster.storage)} storage pools, {len(cluster.ha_groups)} HA groups)")
        # Pick a single node to query (the first one).  In real life we'd
        # hit every node and merge; for now one query is representative.
        first = _find_hv(cluster.hypervisors[0], hvs)
        if first is None or first.type != "proxmox":
            print(f"  [SKIP] no proxmox hypervisor for {cluster.hypervisors[0]}")
            continue
        res = _run_on(first, "ha-manager status")
        if res.returncode != 0:
            print(f"  [FAIL] ha-manager status returned {res.returncode}", file=sys.stderr)
            rc = 1
            continue
        for line in res.stdout.splitlines():
            line = line.rstrip()
            if not line:
                continue
            print(f"  {line}")
        # HA groups
        print(f"  # HA groups: {', '.join(cluster.ha_groups.keys())}")
    return rc


def cmd_drill_ha_failover(args, _) -> int:
    """Simulate a node failure by fencing it via ha-manager.

    Always prompt for confirmation unless --yes is given.  The drill
    is destructive: VMs on the fenced node become "fenced" in the
    real Proxmox HA manager and are live-migrated to a surviving
    node.  Use --unfence to restore the original state.
    """
    try:
        data, nets, hvs, vms, clusters = load_lab(args.lab)
    except LabError as e:
        print(f"[FAIL] {e}", file=sys.stderr)
        return 2
    if not args.node:
        print("--node required for drill-ha-failover", file=sys.stderr)
        return 2
    cluster = None
    for c in clusters:
        if args.node in c.hypervisors:
            cluster = c
            break
    if cluster is None:
        print(f"[FAIL] node '{args.node}' not in any cluster", file=sys.stderr)
        return 1
    hv = _find_hv(args.node, hvs)
    if hv is None or hv.type != "proxmox":
        print(f"[FAIL] '{args.node}' is not a Proxmox hypervisor", file=sys.stderr)
        return 1
    # Pick a surviving node to query status from.
    survivors = [n for n in cluster.hypervisors if n != args.node]
    if not survivors:
        print(f"[FAIL] no surviving node in cluster '{cluster.name}'", file=sys.stderr)
        return 1
    survivor_hv = _find_hv(survivors[0], hvs)
    action = "unfence" if args.unfence else "fence"
    cmd = f"ha-manager {action} {args.node}"
    print(f"# HA failover drill ({action})")
    print(f"#   cluster : {cluster.name}")
    print(f"#   target  : {args.node} ({hv.host})")
    print(f"#   witness : {survivors[0]} ({survivor_hv.host})")
    print(f"#   command : {cmd}")
    if not args.execute:
        print(f"[--] dry-run. Pass --execute to run '{cmd}'.",
              file=sys.stderr)
        return 0
    if not args.yes:
        try:
            ans = input(f"Run 'ha-manager {action} {args.node}'? [y/N] ").strip().lower()
        except EOFError:
            ans = "n"
        if ans not in ("y", "yes"):
            print("Aborted.")
            return 1
    # Run the fence/unfence on the witness node (real Proxmox has the
    # master coordinate HA, so we hit any cluster member).
    res = _run_on(survivor_hv, cmd)
    if res.returncode != 0:
        print(f"[FAIL] ha-manager {action} returned {res.returncode}", file=sys.stderr)
        if res.stderr:
            print(res.stderr, end="", file=sys.stderr)
        return 1
    # Query the resulting status from the witness.
    print(f"[..] {action} OK; status from {survivors[0]}:")
    status = _run_on(survivor_hv, "ha-manager status")
    if status.stdout:
        for line in status.stdout.splitlines():
            if line.strip():
                print(f"  {line.rstrip()}")
    print(f"[OK] HA {action} of {args.node} complete. "
          f"Run scripts/bash/pve-ha-status.sh on {survivors[0]} to confirm.")
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

    sp = sub.add_parser("apply", help="Create VMs in the lab (dry-run by default; --execute to apply)")
    sp.add_argument("--hypervisor", help="Filter to a single hypervisor")
    sp.add_argument("--execute", action="store_true",
                    help="Actually run the commands (default: dry-run)")
    sp.add_argument("--yes", action="store_true",
                    help="Skip the confirmation prompt")
    sp.add_argument("--keep-going", action="store_true",
                    help="Continue on command failure")
    sp.set_defaults(func=cmd_apply)

    sub.add_parser("inventory", help="Print current state of all VMs").set_defaults(func=cmd_inventory)

    sp = sub.add_parser("start", help="Power on VMs in start order")
    sp.add_argument("--vm", help="Single VM name (default: all)")
    sp.set_defaults(func=cmd_start)

    sp = sub.add_parser("stop", help="Power off VMs in reverse start order")
    sp.add_argument("--vm", help="Single VM name (default: all)")
    sp.set_defaults(func=cmd_stop)

    sub.add_parser("backup", help="Show the backup commands for this lab").set_defaults(func=cmd_backup)

    sp =     sub.add_parser("drill", help="Walk a DR drill for one VM")
    sp.add_argument("--vm", required=True, help="VM name")
    sp.set_defaults(func=cmd_drill)

    sp = sub.add_parser("migrate", help="Live-migrate a VM to another node in its cluster")
    sp.add_argument("--vm", required=True, help="VM name to migrate")
    sp.add_argument("--target", required=True, help="Target hypervisor name from lab.yaml")
    sp.add_argument("--mode", choices=["online", "offline"], default="online",
                    help="online = live; offline = stop+move (default: online)")
    sp.add_argument("--execute", action="store_true",
                    help="Actually run the migration (default: dry-run)")
    sp.set_defaults(func=cmd_migrate)

    sub.add_parser("ha-status", help="Show Proxmox HA status for every cluster").set_defaults(func=cmd_ha_status)

    sp = sub.add_parser("drill-ha-failover",
                        help="Fence/unfence a node to drill HA failover")
    sp.add_argument("--node", required=True, help="Hypervisor to fence/unfence")
    sp.add_argument("--unfence", action="store_true",
                    help="Reverse a previous fence (ha-manager unfence)")
    sp.add_argument("--execute", action="store_true",
                    help="Actually run ha-manager fence/unfence (default: dry-run)")
    sp.add_argument("--yes", action="store_true",
                    help="Skip the confirmation prompt")
    sp.set_defaults(func=cmd_drill_ha_failover)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args, parser)


if __name__ == "__main__":
    raise SystemExit(main())
