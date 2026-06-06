"""
Shared fixtures for the labctl integration tests.

We use the docker SDK to build and run the fake-pve container, then
expose helpers to invoke labctl.py as a subprocess and to run ad-hoc
ssh/qm commands inside the container for assertions.

Skips the whole module with a clear reason if docker is not available.
"""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Iterator

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LABCTL = REPO_ROOT / "scripts" / "python" / "labctl.py"
FAKE_PVE_DIR = REPO_ROOT / "lab-test" / "fake-pve"
FIXTURE_KEY = REPO_ROOT / "lab-test" / "fixtures" / "id_ed25519"
FIXTURE_LAB = REPO_ROOT / "lab-test" / "fixtures" / "lab.yaml"
IMAGE_TAG = "lab-test/fake-pve:e2e"
CONTAINER_NAME = "labctl-e2e-fake-pve"


def _docker() -> object | None:
    """Return a docker.DockerClient, or None if docker isn't usable."""
    try:
        import docker  # type: ignore
    except ImportError:
        return None
    try:
        client = docker.from_env()
        client.ping()
        return client
    except Exception:
        return None


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _ssh_ready(host: str, port: int, key: Path, timeout: float = 30.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            cp = subprocess.run(
                [
                    "ssh",
                    "-p", str(port),
                    "-i", str(key),
                    "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "ConnectTimeout=2",
                    f"root@{host}",
                    "--", "true",
                ],
                capture_output=True, text=True, timeout=5,
            )
            if cp.returncode == 0:
                return True
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        time.sleep(0.5)
    return False


@pytest.fixture(scope="session")
def docker_client() -> Iterator[object]:
    """Session-scoped docker client. Skips the test if docker is missing."""
    client = _docker()
    if client is None:
        pytest.skip("docker is not available on this host")
    yield client
    try:
        client.close()
    except Exception:
        pass


@pytest.fixture(scope="session")
def fake_pve_image(docker_client: object) -> str:
    """Build the fake-pve image once per test session."""
    image, _log = docker_client.images.build(  # type: ignore[attr-defined]
        path=str(FAKE_PVE_DIR),
        tag=IMAGE_TAG,
        rm=True, forcerm=True,
    )
    return image.id if hasattr(image, "id") else IMAGE_TAG


@pytest.fixture()
def fake_pve_container(docker_client: object, fake_pve_image: str) -> Iterator[dict]:
    """Run a fresh container with a random host port; tear it down after."""
    port = _free_port()
    # Best-effort cleanup of any leftover container with the same name
    try:
        existing = docker_client.containers.get(CONTAINER_NAME)  # type: ignore[attr-defined]
        existing.remove(force=True)
    except Exception:
        pass

    container = docker_client.containers.run(  # type: ignore[attr-defined]
        IMAGE_TAG,
        name=CONTAINER_NAME,
        detach=True,
        auto_remove=False,
        ports={"22/tcp": ("127.0.0.1", port)},
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
        # Wait for fake qm state to be initialized by entrypoint
        time.sleep(0.5)
        yield info
    finally:
        try:
            container.remove(force=True)
        except Exception:
            pass


@pytest.fixture()
def rendered_lab(request, tmp_path: Path) -> Path:
    """Copy the fixture lab.yaml to tmp_path and rewrite the SSH port.

    Resolves the container fixture the test is using (either
    `fake_pve_container` or `fake_pve_container_failing`) by inspecting
    the test's `request.fixturenames` and resolves only the one that
    was actually requested, so the SSH target matches the running
    container and we don't spin up an extra one.
    """
    if "fake_pve_container_failing" in request.fixturenames:
        container = request.getfixturevalue("fake_pve_container_failing")
    else:
        container = request.getfixturevalue("fake_pve_container")
    content = FIXTURE_LAB.read_text()
    content = content.replace("ssh_port: 2226", f"ssh_port: {container['port']}")
    out = tmp_path / "lab.yaml"
    out.write_text(content)
    return out


@pytest.fixture()
def labctl_env() -> dict:
    """Env vars the labctl subprocess should inherit."""
    env = os.environ.copy()
    env.setdefault("PYTHONUNBUFFERED", "1")
    return env


def run_labctl(args: list[str], env: dict | None = None) -> subprocess.CompletedProcess:
    """Run labctl.py with the given args and return the CompletedProcess."""
    if shutil.which("python3") is None:
        pytest.skip("python3 not on PATH")
    return subprocess.run(
        ["python3", str(LABCTL), *args],
        capture_output=True, text=True, env=env,
        timeout=120,
    )


def docker_exec(container, command: str) -> str:
    """Run `command` inside the container, return stdout."""
    exec_run = container.exec_run(["bash", "-lc", command])
    if exec_run.exit_code != 0:
        raise RuntimeError(
            f"container exec failed (rc={exec_run.exit_code}): "
            f"{(exec_run.output or b'').decode('utf-8', 'ignore')}"
        )
    return (exec_run.output or b"").decode("utf-8")
