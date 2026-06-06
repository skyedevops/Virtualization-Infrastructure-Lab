"""
End-to-end test for labctl.py apply.

Boots a fake Proxmox container, runs validate / plan / apply / inventory
against it, and asserts the fake `qm` shim recorded the expected VMs
in /var/lib/lab/state.json.

This is the test the ROADMAP v1.4 step "End-to-end test of labctl apply
on a fresh VM" refers to.
"""
from __future__ import annotations

import json
import subprocess
import time
from typing import Iterator

import pytest

from .conftest import (
    CONTAINER_NAME,
    FIXTURE_KEY,
    IMAGE_TAG,
    _free_port,
    _ssh_ready,
    docker_exec,
    run_labctl,
)


# ---------------------------------------------------------------------------
# 1. The fake hypervisor itself is usable
# ---------------------------------------------------------------------------
def test_container_ssh_reachable(fake_pve_container: dict) -> None:
    """Sanity check: ssh to the container with the baked-in key works."""
    key = fake_pve_container["ssh_key"]
    port = fake_pve_container["port"]
    cp = subprocess.run(
        [
            "ssh",
            "-p", str(port),
            "-i", str(key),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            f"root@{fake_pve_container['host']}",
            "--", "cat /etc/lab-release",
        ],
        capture_output=True, text=True, timeout=10,
    )
    assert cp.returncode == 0, f"ssh failed: {cp.stderr}"
    assert "fake-pve" in cp.stdout


def test_fake_qm_list_is_empty_initially(fake_pve_container: dict) -> None:
    """The fake `qm` shim should be present and report no VMs at start."""
    container = fake_pve_container["container"]
    out = docker_exec(container, "qm list")
    # First line is the header; nothing else
    assert out.strip().splitlines() == [
        "VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID"
    ]


# ---------------------------------------------------------------------------
# 2. labctl validate / plan against the container
# ---------------------------------------------------------------------------
def test_labctl_validate_accepts_fixture(
    rendered_lab, labctl_env
) -> None:
    cp = run_labctl(["--lab", str(rendered_lab), "validate"], env=labctl_env)
    assert cp.returncode == 0, (
        f"validate failed (rc={cp.returncode})\n"
        f"--- stdout ---\n{cp.stdout}\n--- stderr ---\n{cp.stderr}"
    )
    assert "3 VMs" in cp.stdout
    assert "1 hypervisor" in cp.stdout


def test_labctl_plan_renders_qm_commands(
    rendered_lab, labctl_env
) -> None:
    cp = run_labctl(["--lab", str(rendered_lab), "plan"], env=labctl_env)
    assert cp.returncode == 0, f"plan failed:\n{cp.stderr}"
    out = cp.stdout
    # one qm create per VM
    assert out.count("qm create 900") == 3
    # ctrl01 (vmid 9001) is the first
    assert "qm create 9001 --name ctrl01" in out
    # node02 has the iso
    assert "ide2 local:iso/ubuntu-22.04-server-amd64.iso" in out


def test_labctl_inventory_prints_table(
    rendered_lab, labctl_env
) -> None:
    cp = run_labctl(["--lab", str(rendered_lab), "inventory"], env=labctl_env)
    assert cp.returncode == 0, f"inventory failed:\n{cp.stderr}"
    for name in ("ctrl01", "node01", "node02"):
        assert name in cp.stdout
    assert "VLAN" in cp.stdout  # header


def test_labctl_apply_dry_run_does_not_touch_state(
    rendered_lab, fake_pve_container, labctl_env
) -> None:
    """apply without --execute must print the plan and create no VMs."""
    container = fake_pve_container["container"]
    cp = run_labctl(
        ["--lab", str(rendered_lab), "apply"],
        env=labctl_env,
    )
    assert cp.returncode == 0, f"dry-run apply failed:\n{cp.stderr}"
    assert "dry-run" in cp.stderr
    # qm list in the container should still be empty
    out = docker_exec(container, "qm list")
    assert out.strip().splitlines() == [
        "VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID"
    ]


# ---------------------------------------------------------------------------
# 3. The real deal: apply --execute --yes over SSH
# ---------------------------------------------------------------------------
def test_labctl_apply_creates_all_vms(
    rendered_lab, fake_pve_container, labctl_env
) -> None:
    """apply --execute --yes must run all 3 qm creates via SSH."""
    container = fake_pve_container["container"]
    cp = run_labctl(
        ["--lab", str(rendered_lab), "apply", "--execute", "--yes"],
        env=labctl_env,
    )
    assert cp.returncode == 0, (
        f"apply failed (rc={cp.returncode})\n"
        f"--- stdout ---\n{cp.stdout}\n--- stderr ---\n{cp.stderr}"
    )
    assert "[OK] apply complete." in cp.stdout
    # Each of the 3 VMs got its own transport marker
    assert cp.stdout.count(">>> pve01/") == 3
    assert cp.stdout.count("[OK]") >= 3

    # Now verify state.json inside the container
    state_raw = docker_exec(container, "cat /var/lib/lab/state.json")
    state = json.loads(state_raw)
    names = sorted(v["name"] for v in state["vms"])
    assert names == ["ctrl01", "node01", "node02"]
    for vm in state["vms"]:
        assert vm["status"] == "created"
        assert vm["ostype"] == "l26"
        # The fake shim parsed the virtio+tagged net0 from the qm create call
        assert "virtio" in vm["net"]
        assert f"tag={_net_for_vm(vm['vmid'])}" in vm["net"]

    # And the qm list output should now have 3 rows
    qm_list = docker_exec(container, "qm list")
    rows = [r for r in qm_list.splitlines() if r.strip() and not r.startswith("VMID")]
    assert len(rows) == 3, f"expected 3 rows from qm list, got:\n{qm_list}"


def _net_for_vm(vmid: str) -> str:
    """Return the expected VLAN tag for a VMID (9001 -> 10, others -> 20)."""
    return "10" if vmid == "9001" else "20"


def test_labctl_apply_then_qm_start_flips_status(
    rendered_lab, fake_pve_container, labctl_env
) -> None:
    """apply creates VMs; running `qm start` against them flips status."""
    container = fake_pve_container["container"]
    # Create them
    cp = run_labctl(
        ["--lab", str(rendered_lab), "apply", "--execute", "--yes"],
        env=labctl_env,
    )
    assert cp.returncode == 0, cp.stderr
    # Flip them on via the fake shim
    docker_exec(container, "qm start 9001")
    docker_exec(container, "qm start 9002")
    state = json.loads(docker_exec(container, "cat /var/lib/lab/state.json"))
    statuses = {v["vmid"]: v["status"] for v in state["vms"]}
    assert statuses["9001"] == "running"
    assert statuses["9002"] == "running"
    assert statuses["9003"] == "created"  # untouched


# ---------------------------------------------------------------------------
# 4. Safety: --execute without --yes asks the user
# ---------------------------------------------------------------------------
def test_labctl_apply_requires_yes_for_execute(
    rendered_lab, labctl_env
) -> None:
    """If --execute is set but --yes isn't, we feed 'n' to stdin -> exit 1."""
    from .conftest import LABCTL
    cp = subprocess.run(
        ["python3", str(LABCTL),
         "--lab", str(rendered_lab), "apply", "--execute"],
        input="n\n", capture_output=True, text=True, env=labctl_env, timeout=30,
    )
    assert cp.returncode == 1, (
        f"expected rc=1 (user said no), got {cp.returncode}\n"
        f"stdout: {cp.stdout}\nstderr: {cp.stderr}"
    )
    assert "Aborted" in cp.stdout


# ---------------------------------------------------------------------------
# 5. --keep-going continues past a failing VM
# ---------------------------------------------------------------------------
@pytest.fixture()
def fake_pve_container_failing(docker_client, fake_pve_image, tmp_path) -> Iterator[dict]:
    """A container whose `qm` shim is configured to fail for vmid 9001.

    Built once per test (function scope) by mounting an /etc/lab-test.conf
    that sets `QM_FAIL_VMIDS=9001`.  The shim sources that file on every
    invocation and rejects creates for the listed VMIDs.
    """
    port = _free_port()
    try:
        existing = docker_client.containers.get(CONTAINER_NAME + "-failing")  # type: ignore[attr-defined]
        existing.remove(force=True)
    except Exception:
        pass
    cfg_file = tmp_path / "lab-test.conf"
    cfg_file.write_text("QM_FAIL_VMIDS=9001\n")
    cfg_file.chmod(0o644)
    # Make sure the file is fsynced before docker bind-mounts it
    with cfg_file.open("r+") as f:
        f.flush()
        import os
        os.fsync(f.fileno())
    assert cfg_file.read_text().strip() == "QM_FAIL_VMIDS=9001"
    container = docker_client.containers.run(  # type: ignore[attr-defined]
        IMAGE_TAG,
        name=CONTAINER_NAME + "-failing",
        detach=True,
        auto_remove=False,
        ports={"22/tcp": ("127.0.0.1", port)},
        volumes={str(cfg_file): {"bind": "/etc/lab-test.conf", "mode": "ro"}},
    )
    info = {
        "container": container,
        "host": "127.0.0.1",
        "port": port,
        "ssh_key": FIXTURE_KEY,
    }
    try:
        if not _ssh_ready("127.0.0.1", port, FIXTURE_KEY, timeout=45):
            logs = container.logs(stdout=True, stderr=True).decode("utf-8", "ignore")
            pytest.fail(f"sshd did not become ready on port {port}\n--- container logs ---\n{logs}")
        time.sleep(0.5)
        yield info
    finally:
        try:
            container.remove(force=True)
        except Exception:
            pass


def test_labctl_apply_keep_continues_past_failure(
    rendered_lab, fake_pve_container_failing, labctl_env
) -> None:
    """If a VM fails, --keep-going must continue and provision the rest."""
    container = fake_pve_container_failing["container"]
    cp = run_labctl(
        ["--lab", str(rendered_lab), "apply", "--execute", "--yes", "--keep-going"],
        env=labctl_env,
    )
    # 9001 failed -> non-zero exit
    assert cp.returncode == 1, f"expected rc=1, got {cp.returncode}\nstdout:\n{cp.stdout}\nstderr:\n{cp.stderr}"
    # 2nd and 3rd VMs must have been provisioned
    state = json.loads(docker_exec(container, "cat /var/lib/lab/state.json"))
    names = sorted(v["name"] for v in state["vms"])
    assert names == ["node01", "node02"], f"unexpected VMs: {names}"
    # The stdout should mention the failure
    assert "simulated failure" in cp.stdout or "[FAIL]" in cp.stdout


def test_labctl_apply_aborts_on_failure_without_keep_going(
    rendered_lab, fake_pve_container_failing, labctl_env
) -> None:
    """Without --keep-going, apply must stop on the first failure."""
    container = fake_pve_container_failing["container"]
    cp = run_labctl(
        ["--lab", str(rendered_lab), "apply", "--execute", "--yes"],
        env=labctl_env,
    )
    assert cp.returncode == 1, f"expected rc=1, got {cp.returncode}"
    # 2nd and 3rd VMs must NOT have been provisioned
    state = json.loads(docker_exec(container, "cat /var/lib/lab/state.json"))
    names = [v["name"] for v in state["vms"]]
    assert names == [], f"expected no VMs (abort on first failure), got: {names}"
