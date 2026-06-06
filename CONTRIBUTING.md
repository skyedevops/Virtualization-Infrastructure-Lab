# Contributing

## Ground Rules

1. **One change per PR.** Don't mix a script refactor with a doc update unless
   they're directly related.
2. **Run the linters locally before pushing.** CI will fail if you don't, but
   failing fast on your own machine is faster than failing on `main`.
3. **Update the docs when you update a script.** If you change a CLI flag,
   defaults, or behavior, the corresponding `*.md` file under
   `hypervisors/`, `virtual-machines/`, or `scripts/` should reflect it.
4. **Don't commit secrets, VM disks, or backups.** The `.gitignore` already
   blocks most of these, but if you `git add -f` something, the reviewer will
   catch it.

## Local Lint Quick-Start

```bash
# Bash
shellcheck -S warning <file.sh>

# Python
ruff check <file.py>

# PowerShell
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path <file.ps1> -Severity Error"

# Markdown
markdownlint-cli2 "**/*.md"
```

Install the linters (Ubuntu):

```bash
sudo apt install -y shellcheck
pip install --user ruff
npm install -g markdownlint-cli2
# PowerShell: https://learn.microsoft.com/powershell/scripting/install/installing-powershell
```

## CI

Every push and PR runs `.github/workflows/ci.yml`. The matrix expands to
one job per script + one job for the markdown docs. The CI runs:

- `bash -n` for syntax
- `shellcheck` for bash style / safety
- `ruff` for python
- `PSScriptAnalyzer` for PowerShell
- `markdownlint-cli2` for the docs

## Adding a New Script

1. Drop it under the right `scripts/` subfolder.
2. Add it to the matrix in `.github/workflows/ci.yml` (one line per file).
3. Document it in the corresponding README / `*.md`.
4. Make it executable if it's bash: `chmod +x <file>`.
5. Add a `#Requires` line for PowerShell scripts and a `set -euo pipefail`
   shebang for bash.

## Adding a New Hypervisor

1. Create `hypervisors/<name>/` with `README.md`, `installation.md`, and
   `vm-configuration.md`.
2. Drop any scripts in `hypervisors/<name>/scripts/`.
3. Add each script to the CI matrix.
4. Update the top-level `README.md` "Hypervisors Deployed" table.
5. Add a row to the comparison table in `docs/lab-topology.md`.

## Style

- Bash: `set -euo pipefail`, use `printf` not `echo` for safety, quote
  everything.
- Python: type hints on every public function, `if __name__ == "__main__":`
  guard, `from __future__ import annotations` if you need 3.8 compat.
- PowerShell: `param()` block, `#Requires` for elevation and modules,
  approved verbs for functions.
- Markdown: keep line length reasonable, prefer fenced code blocks with
  language hints (`bash`, `powershell`, `python`, `text`, `mermaid`).
