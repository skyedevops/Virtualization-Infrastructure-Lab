# lab-test

Integration-test fixtures for `labctl.py`.  Lives next to the real lab
config so the fake Proxmox host can be rebuilt and rerun on any
machine with Docker.

## What's in here

| Path                          | Role                                                                 |
|-------------------------------|----------------------------------------------------------------------|
| `fake-pve/`                   | Dockerfile + fake `qm` shim + entrypoint for the fake Proxmox host  |
| `fake-pve/authorized_keys`    | Baked-in pubkey for the test SSH keypair                              |
| `fixtures/lab.yaml`           | Synthetic lab.yaml (1 pve host, 3 VMs) used by the integration test  |
| `fixtures/id_ed25519`         | ed25519 keypair the test uses (no passphrase)                        |
| `fixtures/id_ed25519.pub`     | public half of the keypair                                           |

## Why a fake Proxmox

We need to prove that `labctl.py` provisions VMs correctly *over
SSH* — not just that it generates the right `qm` command lines.  A
unit test with a mock would miss real-world failures (key perms,
host-key prompts, multi-line shell, sshd hardening).  A live
Proxmox cluster would make CI slow and flaky.

The fake-pve container is the middle ground:

- real OpenSSH 8.9 server (not a mock)
- a `qm` shim that records what it would have done in
  `/var/lib/lab/state.json` and `/var/log/lab/qm.log`
- the same command interface a real Proxmox host would expose

The test rebuilds the image, runs a fresh container on a random
port, points `labctl.py` at it, and asserts the fake state.json
matches the plan.  See `../tests/integration/test_apply_e2e.py` and
`../docs/bootstrap-test.md` for the operator-facing version.

## Build and run by hand

```bash
docker build -t lab-test/fake-pve:e2e lab-test/fake-pve
docker run -d --name fake-pve -p 2226:22 lab-test/fake-pve:e2e
sleep 2
ssh -p 2226 -i lab-test/fixtures/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 'whoami; qm list'
# Apply the synthetic lab through labctl
python3 scripts/python/labctl.py --lab lab-test/fixtures/lab.yaml apply
# Then for real (use --execute --yes to actually run)
python3 scripts/python/labctl.py --lab lab-test/fixtures/lab.yaml apply --execute --yes
docker exec fake-pve cat /var/lib/lab/state.json
```

## Fault injection

`/etc/lab-test.conf` is bind-mountable to inject test-time knobs.
The `qm` shim sources it on every call.  Currently the only knob is:

| Variable        | Effect                                                  |
|-----------------|---------------------------------------------------------|
| `QM_FAIL_VMIDS` | Comma-separated VMIDs whose `qm create` will exit 1     |

Example: make a container that fails for vmid 9001:

```bash
printf 'QM_FAIL_VMIDS=9001\n' > /tmp/lab-test.conf
docker run -d --name fake-pve-failing -p 2226:22 \
    -v /tmp/lab-test.conf:/etc/lab-test.conf:ro \
    lab-test/fake-pve:e2e
```

The integration test does exactly this for its `--keep-going` and
abort-on-first-failure cases.
