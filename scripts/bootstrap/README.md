# Bootstrap Scripts

Idempotent scripts that take a bare hypervisor install and turn it into
a lab node ready for `labctl.py apply`.

## Files

| Script | Target | Use case |
|--------|--------|----------|
| `bootstrap.sh` | Proxmox VE 8.x | Run on the Proxmox host after ISO install |
| `bootstrap.ps1` | Windows Server 2019/2022 | Run on the Hyper-V host after OS install |

## Proxmox - `bootstrap.sh`

```bash
# Default (clones the public repo, no apply):
curl -fsSL https://raw.githubusercontent.com/skyedevops/Virtualization-Infrastructure-Lab/main/scripts/bootstrap/bootstrap.sh | bash

# Custom repo + branch + SSH key:
LAB_REPO=https://github.com/<you>/<fork>.git \
LAB_BRANCH=main \
SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub \
bash bootstrap.sh

# Full: bootstrap + apply:
bash bootstrap.sh --apply
```

Skip flags:

- `--skip-harden` - do not re-run `pve-post-install.sh`
- `--skip-network` - do not patch `vmbr0` for VLAN awareness
- `--skip-storage` - do not verify default storages

The script is safe to re-run.

## Hyper-V - `bootstrap.ps1`

```powershell
# From the Hyper-V host, in an elevated PowerShell:
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/skyedevops/Virtualization-Infrastructure-Lab/main/scripts/bootstrap/bootstrap.ps1 | Invoke-Expression

# Or, from a local checkout of the repo:
.\scripts\bootstrap\bootstrap.ps1
.\scripts\bootstrap\bootstrap.ps1 -Apply
```

What it does:

1. Enables the Hyper-V role + management tools
2. Configures default VM / VHD / ISO paths
3. Creates `vSwitch-External`, `vSwitch-Internal`, `vSwitch-Private`
4. Installs Python + PyYAML for `labctl`
5. Clones / updates the lab repo
6. (Optional) Runs `labctl apply` against this host

## Idempotency

Both scripts use `if (-not (Get-...))` / `if ! command -v` patterns.
Running them twice in a row is a no-op the second time, except for
the lab repo pull which `git pull --ff-only`s.

## Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `pveversion not found` | not a Proxmox host | wrong host |
| `Hyper-V feature not available` | not a Windows Pro/Server SKU | re-install with Pro/Server |
| `hypervisor in lab.yaml targets X` warning | lab.yaml is generic | edit `lab.yaml` to add this host, or use a per-host fork |
| `qm not found` on a remote PVE via SSH | not a Proxmox host OR path issue | check `ssh_user` is root and host is the PVE IP |

## After Bootstrap

```bash
# On either host, with the lab repo at $LAB_PATH:
cd $LAB_PATH
python3 scripts/python/labctl.py validate
python3 scripts/python/labctl.py plan
python3 scripts/python/labctl.py apply --execute --yes
```

See [docs/lab-yaml-schema.md](../../docs/lab-yaml-schema.md) for the
inventory schema and [../../ROADMAP.md](../../ROADMAP.md) for the wider
project roadmap.
