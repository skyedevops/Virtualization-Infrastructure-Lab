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
FAKE_PBS_DIR = REPO_ROOT / "lab-test" / "fake-pbs"
FIXTURE_KEY = REPO_ROOT / "lab-test" / "fixtures" / "id_ed25519"
FIXTURE_LAB = REPO_ROOT / "lab-test" / "fixtures" / "lab.yaml"
FIXTURE_PBS_LAB = REPO_ROOT / "lab-test" / "fixtures" / "lab-pbs.yaml"
IMAGE_TAG = "lab-test/fake-pve:e2e"
PBS_IMAGE_TAG = "lab-test/fake-pbs:e2e"
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


@pytest.fixture(scope="session")
def fake_pbs_image(docker_client: object) -> str:
    """Build the fake-pbs image once per test session."""
    image, _log = docker_client.images.build(  # type: ignore[attr-defined]
        path=str(FAKE_PBS_DIR),
        tag=PBS_IMAGE_TAG,
        rm=True, forcerm=True,
    )
    return image.id if hasattr(image, "id") else PBS_IMAGE_TAG


PBS_CONTAINER_NAME = "labctl-e2e-fake-pbs"


@pytest.fixture()
def fake_pbs_container(docker_client: object, fake_pbs_image: str) -> Iterator[dict]:
    """Run a fresh fake-pbs container with a random host port; tear it down after."""
    port = _free_port()
    try:
        existing = docker_client.containers.get(PBS_CONTAINER_NAME)  # type: ignore[attr-defined]
        existing.remove(force=True)
    except Exception:
        pass

    container = docker_client.containers.run(  # type: ignore[attr-defined]
        PBS_IMAGE_TAG,
        name=PBS_CONTAINER_NAME,
        detach=True,
        auto_remove=False,
        ports={"22/tcp": ("127.0.0.1", port)},
    )
    info = {
        "container": container,
        "host": "127.0.0.1",
        "port": port,
        "ssh_key": FIXTURE_KEY,
        "node_name": "pbs01",
    }
    try:
        if not _ssh_ready("127.0.0.1", port, FIXTURE_KEY, timeout=45):
            logs = container.logs(stdout=True, stderr=True).decode("utf-8", "ignore")
            pytest.fail(f"fake-pbs sshd did not become ready on port {port}\n--- container logs ---\n{logs}")
        time.sleep(0.5)
        yield info
    finally:
        try:
            container.remove(force=True)
        except Exception:
            pass


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
        "node_name": "pve01",
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


# -----------------------------------------------------------------------------
# v2.0 - multi-host cluster fixtures
# -----------------------------------------------------------------------------
CLUSTER_LAB = REPO_ROOT / "lab-test" / "fixtures" / "lab-cluster.yaml"


def _start_fake_pve(docker_client, image_id: str, name: str, node: str) -> dict:
    """Helper: run a fake-pve container with FAKE_NODE_NAME set so the
    shim stamps VM records with the right cluster node name.
    """
    port = _free_port()
    # Best-effort cleanup
    try:
        existing = docker_client.containers.get(name)  # type: ignore[attr-defined]
        existing.remove(force=True)
    except Exception:
        pass
    container = docker_client.containers.run(  # type: ignore[attr-defined]
        image_id,
        name=name,
        detach=True,
        auto_remove=False,
        ports={"22/tcp": ("127.0.0.1", port)},
        environment={"FAKE_NODE_NAME": node},
    )
    info = {
        "container": container,
        "host": "127.0.0.1",
        "port": port,
        "ssh_key": FIXTURE_KEY,
        "node_name": node,
    }
    if not _ssh_ready("127.0.0.1", port, FIXTURE_KEY, timeout=45):
        logs = container.logs(stdout=True, stderr=True).decode("utf-8", "ignore")
        container.remove(force=True)
        pytest.fail(f"sshd did not become ready on port {port}\n--- container logs ---\n{logs}")
    time.sleep(0.3)
    return info


@pytest.fixture()
def fake_pve_cluster(docker_client: object, fake_pve_image: str) -> Iterator[list[dict]]:
    """Spin up a 2-node fake-pve cluster (pve01, pve02)."""
    nodes = [
        ("labctl-cluster-pve01", "pve01"),
        ("labctl-cluster-pve02", "pve02"),
    ]
    started: list[dict] = []
    try:
        for cname, nname in nodes:
            started.append(_start_fake_pve(docker_client, fake_pve_image, cname, nname))
        yield started
    finally:
        for info in started:
            try:
                info["container"].remove(force=True)
            except Exception:
                pass


@pytest.fixture()
def rendered_cluster_lab(request, tmp_path: Path) -> Path:
    """Materialise a 2-node cluster lab.yaml pointing at the running
    fake_pve_cluster containers.

    The fixture file uses two named placeholders that the test rewrites
    to the actual host ports for each running container:

        ssh_port_pve01: 22001   <-- rewritten to pve01's port
        ssh_port_pve02: 22002   <-- rewritten to pve02's port

    We then rename the placeholders to the real key the labctl SSH
    transport reads (`ssh_port: <n>`).  Both placeholders are looked up
    directly so we don't depend on the node-name suffix arithmetic.
    """
    cluster = request.getfixturevalue("fake_pve_cluster")
    by_node = {n["node_name"]: n for n in cluster}
    content = CLUSTER_LAB.read_text()
    # Map of placeholder -> node name -> port
    placeholders = {
        "pve01": "ssh_port_pve01: 22001",
        "pve02": "ssh_port_pve02: 22002",
    }
    for node_name, placeholder in placeholders.items():
        info = by_node[node_name]
        content = content.replace(placeholder, f"ssh_port: {info['port']}")
    out = tmp_path / "lab.yaml"
    out.write_text(content)
    return out


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
def rendered_pbs_lab(
    request, tmp_path: Path,
    fake_pve_container, fake_pbs_container,
) -> Path:
    """Materialise lab-pbs.yaml pointing at the running fake_pve_container
    + fake_pbs_container.  We pass both fixtures as function args so they
    start for this test.
    """
    content = FIXTURE_PBS_LAB.read_text()
    content = content.replace(
        "ssh_port_pve01: 23001",
        f"ssh_port: {fake_pve_container['port']}",
    )
    content = content.replace(
        "ssh_port_pbs01: 23002",
        f"ssh_port: {fake_pbs_container['port']}",
    )
    out = tmp_path / "lab.yaml"
    out.write_text(content)
    return out


@pytest.fixture()
def labctl_env() -> dict:
    """Env vars the labctl subprocess should inherit."""
    env = os.environ.copy()
    env.setdefault("PYTHONUNBUFFERED", "1")
    return env


@pytest.fixture()
def repo_root() -> Path:
    """Absolute path to the repo root (scripts/, docs/, etc.)."""
    return REPO_ROOT


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
