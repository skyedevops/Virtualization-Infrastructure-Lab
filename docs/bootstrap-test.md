# End-to-end test of `labctl.py apply` (v1.4 deferred)

This document is the operator-facing companion to the
`tests/integration/test_apply_e2e.py` suite.  It explains what the
test covers, how to run it by hand, and what to do when it fails.

## What it proves

The integration test drives the real `labctl.py` against a fake Proxmox
container (`lab-test/fake-pve`) to prove that the SSH transport, the
`qm` command generator, the plan/apply loop, the `--yes` prompt, the
`--keep-going` flag, and the per-command error reporting all work the
way the rest of the lab expects.  In one command:

```text
python3 scripts/python/labctl.py --lab lab-test/fixtures/lab.yaml \
    apply --execute --yes
```

…must successfully `qm create` three test VMs over SSH.

## Layout

| Path                                      | What it is                                  |
|-------------------------------------------|---------------------------------------------|
| `lab-test/fake-pve/Dockerfile`            | Ubuntu 22.04 + sshd + the fake `qm` shim    |
| `lab-test/fake-pve/qm`                    | Bash shim: logs to `state.json` + `qm.log`  |
| `lab-test/fake-pve/entrypoint.sh`         | Brings sshd up; initialises state.json      |
| `lab-test/fake-pve/authorized_keys`       | Baked-in pubkey for the e2e test keypair    |
| `lab-test/fixtures/lab.yaml`              | Synthetic lab.yaml (1 pve host, 3 VMs)     |
| `lab-test/fixtures/id_ed25519`            | ed25519 keypair the test uses               |
| `lab-test/fixtures/id_ed25519.pub`        | public half (same as `authorized_keys`)     |
| `tests/integration/conftest.py`           | docker + ssh-fixture plumbing               |
| `tests/integration/test_apply_e2e.py`     | 11 test cases covering plan/apply/safety    |

## Run it locally

```bash
# 1. Build the fake-pve image (Ubuntu 22.04 + sshd + fake qm).
docker build -t lab-test/fake-pve:e2e lab-test/fake-pve

# 2. Install the python deps the test needs.
python3 -m pip install pytest docker pyyaml

# 3. Run the suite.
python3 -m pytest tests/integration/ -v
```

The whole suite finishes in ~30 seconds on a workstation.

## What each test case covers

| Test                                            | What it proves                                            |
|-------------------------------------------------|-----------------------------------------------------------|
| `test_container_ssh_reachable`                  | Key auth + sshd healthcheck inside the container          |
| `test_fake_qm_list_is_empty_initially`          | The fake shim's initial state is empty                    |
| `test_labctl_validate_accepts_fixture`          | `validate` accepts the synthetic lab.yaml                 |
| `test_labctl_plan_renders_qm_commands`          | `plan` emits real `qm create` lines for every VM          |
| `test_labctl_inventory_prints_table`            | `inventory` prints the table view                         |
| `test_labctl_apply_dry_run_does_not_touch_state`| `apply` without `--execute` is a no-op                    |
| `test_labctl_apply_creates_all_vms`             | `apply --execute --yes` provisions all 3 VMs over SSH     |
| `test_labctl_apply_then_qm_start_flips_status`  | `qm start` via the shim flips `status` to `running`       |
| `test_labctl_apply_requires_yes_for_execute`    | `--execute` without `--yes` and 'n' on stdin => rc=1      |
| `test_labctl_apply_keep_continues_past_failure` | `--keep-going` provisions the remaining VMs after a fail  |
| `test_labctl_apply_aborts_on_failure_without_keep_going` | First failure aborts the run                 |

## How the fault-injection works

The `--keep-going` and abort-on-failure tests need a way to make
`qm create` exit non-zero for one VMID.  We can't reach for a real
Proxmox host (this is a unit test, not a soak test), so the shim reads
`/etc/lab-test.conf` on every invocation:

```bash
if [[ -n "${QM_FAIL_VMIDS:-}" ]]; then
  IFS=',' read -r -a fails <<< "$QM_FAIL_VMIDS"
  for f in "${fails[@]}"; do
    if [[ "$f" == "$vmid" ]]; then
      echo "simulated failure for vmid=$vmid" >&2
      exit 1
    fi
  done
fi
```

The `fake_pve_container_failing` fixture bind-mounts a tmpfile as
`/etc/lab-test.conf` with `QM_FAIL_VMIDS=9001` written into it.  The
shim rejects VMID 9001, all other VMIDs pass.  This avoids both
`docker run -e ...` (sanitized by sshd) and on-the-fly shim editing
(which would race with the other tests).

## CI

`.github/workflows/ci.yml` defines a `labctl integration (fake-pve)`
job that:

1. Installs `pytest`, `docker`, `pyyaml`, `ruff`.
2. Runs `ruff check tests/` (lints the new code).
3. Starts the GitHub-hosted docker daemon.
4. Runs `python -m pytest tests/integration/ -v`.

It is wired to `needs: python` so a syntax/lint failure fails the
suite before we spend 30 seconds on the integration test.

## Debugging a red build

1. Check the docker daemon is running: `docker info` must succeed.
2. Build the image by hand and start it interactively:

   ```bash
   docker build -t lab-test/fake-pve:e2e lab-test/fake-pve
   docker run -d --name fake-pve -p 2226:22 lab-test/fake-pve:e2e
   sleep 2
   ssh -p 2226 -i lab-test/fixtures/id_ed25519 \
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       root@127.0.0.1 'whoami; qm list'
   ```

3. Run a single failing test with `-v -s` to see the stdout/stderr of
   the `labctl` subprocess:

   ```bash
   python3 -m pytest tests/integration/test_apply_e2e.py::test_labctl_apply_creates_all_vms -v -s
   ```

4. If the shim is doing the wrong thing, look at the audit trail it
   leaves behind:

   ```bash
   docker exec fake-pve cat /var/log/lab/qm.log
   docker exec fake-pve cat /var/lib/lab/state.json
   ```

## When to add a test here

Add a new test case to `tests/integration/test_apply_e2e.py` whenever
you change:

- the SSH / PowerShell transport in `scripts/python/labctl.py`
- the per-hypervisor command generators
- the safety flags (`--execute`, `--yes`, `--keep-going`)
- the validation rules for `lab.yaml`

A pure doc fix or a change to a `qm` argument is not enough of a
reason on its own, but a one-line addition to the test asserting the
new argument is cheap and prevents regressions.
