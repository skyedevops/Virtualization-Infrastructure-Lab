"""End-to-end tests for the v2.0 multi-host cluster lifecycle.

These tests spin up two fake-pve containers (pve01, pve02) and verify
that labctl.py can:
  - apply a 2-VM lab across the cluster
  - show HA status (which talks to ha-manager over SSH)
  - live-migrate a VM from pve01 to pve02 and see the state.json update
  - drill-ha-failover a node (ha-manager fence) and see resources go
    into "fenced" state
  - unfence and see them come back

Skipped (with reason) if docker is not available on the host.
"""
from __future__ import annotations

import json

from .conftest import docker_exec, run_labctl


def _node_vmids(node: str, cluster: list[dict]) -> dict:
    """Return the JSON state of /var/lib/lab/state.json from `node`."""
    info = next(n for n in cluster if n["node_name"] == node)
    raw = docker_exec(info["container"], "cat /var/lib/lab/state.json")
    return json.loads(raw)


def _node_ha(node: str, cluster: list[dict]) -> list[str]:
    """Return `ha-manager status` output for `node`, one line per resource."""
    info = next(n for n in cluster if n["node_name"] == node)
    out = docker_exec(info["container"], "ha-manager status")
    return [ln for ln in out.splitlines() if ln.strip()]


# -----------------------------------------------------------------------------
# 1. Validation: the fixture lab.yaml is structurally valid
# -----------------------------------------------------------------------------
def test_cluster_lab_validates(rendered_cluster_lab, labctl_env):
    cp = run_labctl(["--lab", str(rendered_cluster_lab), "validate"], env=labctl_env)
    assert cp.returncode == 0, f"validate failed: {cp.stderr}"
    assert "2 VMs across 2 hypervisor" in cp.stdout
    assert "1 cluster" in cp.stdout


# -----------------------------------------------------------------------------
# 2. Plan: emits the per-cluster commands and ha-manager add
# -----------------------------------------------------------------------------
def test_cluster_plan_emits_ceph_and_ha(rendered_cluster_lab, labctl_env):
    cp = run_labctl(["--lab", str(rendered_cluster_lab), "plan"], env=labctl_env)
    assert cp.returncode == 0, f"plan failed: {cp.stderr}"
    assert "--scsi0 ceph-rbd:" in cp.stdout
    # Per-VM HA group emitted
    assert "ha-manager add vm:1001 --group default" in cp.stdout
    assert "ha-manager add vm:1002 --group tier1" in cp.stdout
    # The cluster tag is in the per-VM header
    assert "cluster=prod" in cp.stdout


# -----------------------------------------------------------------------------
# 3. Apply: real qm create + ha-manager add across the cluster
# -----------------------------------------------------------------------------
def test_cluster_apply_provisions_on_pve01(rendered_cluster_lab, labctl_env,
                                            fake_pve_cluster):
    cp = run_labctl(
        ["--lab", str(rendered_cluster_lab), "apply",
         "--execute", "--yes", "--hypervisor", "pve01"],
        env=labctl_env,
    )
    assert cp.returncode == 0, f"apply failed: stdout={cp.stdout!r} stderr={cp.stderr!r}"

    pve01_state = _node_vmids("pve01", fake_pve_cluster)
    names = {v["name"] for v in pve01_state["vms"]}
    assert {"web01", "db01"} <= names, f"pve01 state missing VMs: {pve01_state}"

    # All VMs are on pve01 (the lab's initial placement)
    for v in pve01_state["vms"]:
        assert v["node"] == "pve01", f"VM {v['name']} not on pve01: {v}"

    # HA resources were registered
    ha = _node_ha("pve01", fake_pve_cluster)
    assert any("1001" in ln and "started" in ln and "default" in ln for ln in ha), \
        f"web01 HA resource missing: {ha}"
    assert any("1002" in ln and "started" in ln and "tier1" in ln for ln in ha), \
        f"db01 HA resource missing: {ha}"


# -----------------------------------------------------------------------------
# 4. Migrate: VM moves pve01 -> pve02, source node's state records it
# -----------------------------------------------------------------------------
def test_cluster_migrate_moves_vm_to_pve02(rendered_cluster_lab, labctl_env,
                                           fake_pve_cluster):
    # First apply
    apply = run_labctl(
        ["--lab", str(rendered_cluster_lab), "apply",
         "--execute", "--yes", "--hypervisor", "pve01"],
        env=labctl_env,
    )
    assert apply.returncode == 0, f"setup apply failed: {apply.stderr}"

    # Then migrate web01
    mig = run_labctl(
        ["--lab", str(rendered_cluster_lab), "migrate",
         "--vm", "web01", "--target", "pve02", "--execute"],
        env=labctl_env,
    )
    assert mig.returncode == 0, f"migrate failed: stdout={mig.stdout!r} stderr={mig.stderr!r}"
    assert "qm migrate 1001 pve02" in mig.stdout

    # The fake shim updates the source node's state.json in place: the
    # VM's `node` field flips to the target.  In real Proxmox the VM
    # is unregistered on the source and registered on the target, but
    # the in-shim representation is the same logical claim: the VM
    # now lives on pve02.
    pve01_state = _node_vmids("pve01", fake_pve_cluster)
    moved = [v for v in pve01_state["vms"] if v["vmid"] == "1001"]
    assert moved, f"web01 missing from pve01 state: {pve01_state}"
    assert moved[0]["node"] == "pve02", \
        f"web01 still on {moved[0]['node']}: {moved[0]}"


# -----------------------------------------------------------------------------
# 5. Migrate: refuses to migrate to the same node
# -----------------------------------------------------------------------------
def test_cluster_migrate_refuses_same_node(rendered_cluster_lab, labctl_env):
    cp = run_labctl(
        ["--lab", str(rendered_cluster_lab), "migrate",
         "--vm", "web01", "--target", "pve01", "--execute"],
        env=labctl_env,
    )
    assert cp.returncode != 0
    assert "target == source" in cp.stderr


# -----------------------------------------------------------------------------
# 6. HA drill: fence a node and observe "fenced" state
# -----------------------------------------------------------------------------
def test_cluster_drill_fence_and_unfence(rendered_cluster_lab, labctl_env,
                                        fake_pve_cluster):
    # Apply so HA resources exist
    apply = run_labctl(
        ["--lab", str(rendered_cluster_lab), "apply",
         "--execute", "--yes", "--hypervisor", "pve01"],
        env=labctl_env,
    )
    assert apply.returncode == 0, f"setup apply failed: {apply.stderr}"

    # Fence pve01
    fence = run_labctl(
        ["--lab", str(rendered_cluster_lab), "drill-ha-failover",
         "--node", "pve01", "--execute", "--yes"],
        env=labctl_env,
    )
    assert fence.returncode == 0, f"fence failed: stdout={fence.stdout!r} stderr={fence.stderr!r}"
    assert "ha-manager fence pve01" in fence.stdout

    # The witness (pve02) records the fence.  In real Proxmox the
    # cluster manager propagates fence state to every node; in the
    # fake, the witness's ha-manager status echoes the fenced-node
    # marker.
    ha = _node_ha("pve02", fake_pve_cluster)
    assert any("FENCED NODE: pve01" in ln for ln in ha), \
        f"witness did not record the fence: {ha}"

    # Unfence and verify the witness no longer reports the fence
    unfence = run_labctl(
        ["--lab", str(rendered_cluster_lab), "drill-ha-failover",
         "--node", "pve01", "--unfence", "--execute", "--yes"],
        env=labctl_env,
    )
    assert unfence.returncode == 0, f"unfence failed: {unfence.stderr}"
    ha_after = _node_ha("pve02", fake_pve_cluster)
    assert all("FENCED NODE" not in ln for ln in ha_after), \
        f"witness still reports fence after unfence: {ha_after}"


# -----------------------------------------------------------------------------
# 7. HA status: returns a parseable report for the cluster
# -----------------------------------------------------------------------------
def test_cluster_ha_status_runs(rendered_cluster_lab, labctl_env, fake_pve_cluster):
    # Apply first so HA resources exist
    apply = run_labctl(
        ["--lab", str(rendered_cluster_lab), "apply",
         "--execute", "--yes", "--hypervisor", "pve01"],
        env=labctl_env,
    )
    assert apply.returncode == 0, f"setup apply failed: {apply.stderr}"

    # ha-status will try to SSH to pve01 (the first member of the cluster).
    # That is the same container fake_pve_cluster[0], so the SSH call
    # should succeed.  We don't need to assert specific VM numbers
    # (depends on which node is "first"); just that the report runs.
    status = run_labctl(
        ["--lab", str(rendered_cluster_lab), "ha-status"],
        env=labctl_env,
    )
    # The ha-status command should not crash, regardless of returncode
    # (it may return non-zero if any HA resource is "fenced" or there
    # are zero resources, which is also fine for this test).
    assert "Cluster: prod" in status.stdout or "Cluster: prod" in status.stderr, \
        f"cluster report missing: stdout={status.stdout!r} stderr={status.stderr!r}"
