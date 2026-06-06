"""
End-to-end test for the labctl Proxmox Backup Server (PBS) subcommands.

Boots a fake Proxmox container AND a fake PBS container over SSH, then
exercises the v2.1 PBS subcommands against them: validate, pbs-status,
pbs-init, backup (with --execute), pbs-restore-test, and the bash
runbook pbs-restore-test.sh.  The fake proxmox-backup-manager shim
records every call to /var/lib/pbs/state.json, which is what we assert
on.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path


from .conftest import (
    docker_exec,
    run_labctl,
)


# ---------------------------------------------------------------------------
# 1. The fake PBS itself is reachable + has an empty state
# ---------------------------------------------------------------------------
def test_fake_pbs_ssh_reachable(fake_pbs_container: dict) -> None:
    """Sanity check: ssh into the fake PBS works and the shim is on PATH."""
    key = fake_pbs_container["ssh_key"]
    port = fake_pbs_container["port"]
    cp = subprocess.run(
        [
            "ssh", "-p", str(port),
            "-i", str(key),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            f"root@{fake_pbs_container['host']}",
            "--", "which proxmox-backup-manager && cat /etc/pbs-release",
        ],
        capture_output=True, text=True, timeout=10,
    )
    assert cp.returncode == 0, cp.stderr
    assert "/usr/local/bin/proxmox-backup-manager" in cp.stdout
    assert "fake-pbs:" in cp.stdout


def test_fake_pbs_initial_state_is_empty(fake_pbs_container: dict) -> None:
    """The shim writes an empty state.json on first boot."""
    out = docker_exec(fake_pbs_container["container"], "cat /var/lib/pbs/state.json")
    state = json.loads(out)
    assert state == {"datastores": {}, "snapshots": {}, "prune_jobs": {}}


# ---------------------------------------------------------------------------
# 2. labctl pbs-status (read-only)
# ---------------------------------------------------------------------------
def test_pbs_status_dry_run(rendered_pbs_lab: Path, labctl_env: dict) -> None:
    """pbs-status should report the PBS server header (2 declared, 0 live)."""
    cp = run_labctl(["--lab", str(rendered_pbs_lab), "pbs-status"], env=labctl_env)
    assert cp.returncode == 0, cp.stdout + cp.stderr
    assert "pbs01" in cp.stdout
    # 2 datastores are declared in lab-pbs.yaml (main + offsite) ...
    assert "2 datastore(s) declared" in cp.stdout
    # ... but 0 are registered on the PBS host yet (no pbs-init has run).
    assert "0 datastore(s) registered" in cp.stdout


# ---------------------------------------------------------------------------
# 3. labctl pbs-init (with + without --execute)
# ---------------------------------------------------------------------------
def test_pbs_init_dry_run_does_not_change_state(
    rendered_pbs_lab: Path,
    labctl_env: dict,
    fake_pbs_container: dict,
) -> None:
    """Dry-run pbs-init must NOT call proxmox-backup-manager on the PBS."""
    cp = run_labctl(
        ["--lab", str(rendered_pbs_lab), "pbs-init"], env=labctl_env,
    )
    assert cp.returncode == 0, cp.stdout + cp.stderr
    assert "datastore create" in cp.stdout
    assert "prune-job create" in cp.stdout

    out = docker_exec(fake_pbs_container["container"], "cat /var/lib/pbs/state.json")
    state = json.loads(out)
    assert state["datastores"] == {}
    assert state["prune_jobs"] == {}


def test_pbs_init_execute_creates_datastores_and_prune_jobs(
    rendered_pbs_lab: Path,
    labctl_env: dict,
    fake_pbs_container: dict,
) -> None:
    """--execute should run proxmox-backup-manager on the PBS and update state."""
    cp = run_labctl(
        ["--lab", str(rendered_pbs_lab), "pbs-init", "--execute"], env=labctl_env,
    )
    assert cp.returncode == 0, cp.stdout + cp.stderr

    out = docker_exec(fake_pbs_container["container"], "cat /var/lib/pbs/state.json")
    state = json.loads(out)
    assert "main" in state["datastores"], state
    assert "offsite" in state["datastores"], state
    assert state["datastores"]["main"] == "/backup/pbs/main"
    # prune jobs: one per datastore
    assert any("main" in k for k in state["prune_jobs"]), state
    assert any("offsite" in k for k in state["prune_jobs"]), state


def test_pbs_init_is_idempotent(
    rendered_pbs_lab: Path,
    labctl_env: dict,
) -> None:
    """Re-running pbs-init --execute should not fail (jobs are updated, not duplicated)."""
    cp1 = run_labctl(
        ["--lab", str(rendered_pbs_lab), "pbs-init", "--execute"], env=labctl_env,
    )
    assert cp1.returncode == 0, cp1.stdout + cp1.stderr
    cp2 = run_labctl(
        ["--lab", str(rendered_pbs_lab), "pbs-init", "--execute"], env=labctl_env,
    )
    assert cp2.returncode == 0, cp2.stdout + cp2.stderr


# ---------------------------------------------------------------------------
# 4. labctl backup (creates snapshots via the source PVE node)
# ---------------------------------------------------------------------------
def test_backup_emits_proxmox_backup_manager_commands(
    rendered_pbs_lab: Path,
    labctl_env: dict,
    fake_pve_container: dict,
) -> None:
    """`labctl backup` (dry-run) should print one proxmox-backup-manager triple per job.

    Each job emits exactly ONE primary `  $ proxmox-backup-manager backup` line
    (plus another occurrence inside the `job create --backup ...` arg), so we
    assert on the anchored primary form.
    """
    cp = run_labctl(["--lab", str(rendered_pbs_lab), "backup"], env=labctl_env)
    assert cp.returncode == 0, cp.stdout + cp.stderr
    # Two jobs in the fixture => 2 primary backup + 2 primary prune + 2 job-create.
    assert cp.stdout.count("  $ proxmox-backup-manager backup ") == 2
    assert cp.stdout.count("  $ proxmox-backup-manager prune ") == 2
    assert cp.stdout.count("  $ proxmox-backup-manager job create ") == 2


def test_backup_execute_runs_via_ssh(
    rendered_pbs_lab: Path,
    labctl_env: dict,
    fake_pve_container: dict,
) -> None:
    """--execute should run the backup commands on the source PVE, which
    SSHes into PBS to do the actual data push.  In our shim world the
    fake-pve image has the proxmox-backup-manager shim baked in, so the
    command runs locally and writes to /var/lib/pbs/state.json inside
    the PVE container.  This proves the SSH-from-labctl-to-PVE path
    and the command-line contract; a real deployment would have the
    PVE node forward the stream to a remote PBS host.
    """
    cp = run_labctl(
        ["--lab", str(rendered_pbs_lab), "backup", "--execute"], env=labctl_env,
    )
    assert cp.returncode == 0, cp.stdout + cp.stderr

    # Snapshots end up in the fake-pve's local /var/lib/pbs/state.json.
    out = docker_exec(fake_pve_container["container"], "cat /var/lib/pbs/state.json")
    state = json.loads(out)
    assert state["snapshots"], "expected at least one snapshot to be recorded"
    # Both jobs in the fixture fire: web01->main and db01->offsite.
    # The fake shim stores them as host/pbs01/backup/<vmid>/<timestamp>
    # so we assert on VMID, not on datastore prefix.
    snap_keys = list(state["snapshots"].keys())
    assert any("/2001/" in k for k in snap_keys), snap_keys  # web01 VMID
    assert any("/2002/" in k for k in snap_keys), snap_keys  # db01  VMID


# ---------------------------------------------------------------------------
# 5. The bash runbook pbs-restore-test.sh round-trips a backup
# ---------------------------------------------------------------------------
def test_pbs_restore_test_bash_runbook(
    rendered_pbs_lab: Path,
    labctl_env: dict,
    fake_pve_container: dict,
    fake_pbs_container: dict,
    repo_root: Path,
) -> None:
    """End-to-end: back up a VM via labctl, then run pbs-restore-test.sh
    over ssh on the PBS host and assert a restore-test-* VM was created.
    """
    # First, back up web01
    cp = run_labctl(
        ["--lab", str(rendered_pbs_lab), "backup", "--vm", "web01", "--execute"],
        env=labctl_env,
    )
    assert cp.returncode == 0, cp.stdout + cp.stderr

    # Then run pbs-restore-test.sh on the PVE host (where `qm` lives
    # in real prod).  The script will SSH to the PBS host to list
    # snapshots; in our integration test the fake-pve container has
    # its own proxmox-backup-manager shim that records snapshots to
    # /var/lib/pbs/state.json locally, so the snapshot list is
    # returned by the shim, not by ssh-to-PBS.  Either way the
    # round-trip is exercised.
    script = repo_root / "scripts" / "bash" / "pbs-restore-test.sh"
    assert script.exists()
    script_body = script.read_text()
    key = fake_pve_container["ssh_key"]
    port = fake_pve_container["port"]
    rendered_lab_path = str(rendered_pbs_lab)
    # Pipe the script via stdin so we don't need the path to exist in
    # the container (which is convenient for CI; the script body is
    # immutable per-commit).
    cp = subprocess.run(
        [
            "ssh", "-p", str(port),
            "-i", str(key),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            f"root@{fake_pve_container['host']}",
            "--", f"LAB={rendered_lab_path} bash -s -- --datastore pbs01/main --execute 2>&1",
        ],
        input=script_body,
        capture_output=True, text=True, timeout=60,
    )
    assert cp.returncode == 0, cp.stdout + cp.stderr
    # The script tears down the restore-test VM in its EXIT trap, so
    # /var/lib/lab/state.json is back to empty by the time we check.
    # Instead, assert on the script's own log file (which it writes
    # to /var/log/pbs-restore-test.log) and on the per-command qm log
    # in /var/log/lab/qm.log, both of which persist.
    log = docker_exec(
        fake_pve_container["container"], "cat /var/log/pbs-restore-test.log",
    )
    assert "[OK] restore-test of" in log, log
    assert "vmid=92001" in log  # the restored test VMID was 9 + 2001
    qm_log = docker_exec(
        fake_pve_container["container"], "cat /var/log/lab/qm.log",
    )
    assert "restore:" in qm_log, qm_log
    # Verify the qm shim recorded a restore call with VMID 92001.
    assert "vmid=92001" in qm_log, qm_log
