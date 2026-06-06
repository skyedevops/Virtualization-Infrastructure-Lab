## Summary

<!-- 1-3 sentences on what this PR does and why. -->

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [ ] Documentation update
- [ ] Refactor / cleanup
- [ ] Script addition / modification

## Areas Touched

<!-- Check all that apply. CI runs the relevant linter for each area. -->

- [ ] Hypervisor doc (`hypervisors/*`)
- [ ] Guest VM doc (`virtual-machines/*`)
- [ ] Networking / DR / Sizing doc
- [ ] Bash script - runs `shellcheck`
- [ ] Python script - runs `ruff`
- [ ] PowerShell script - runs `PSScriptAnalyzer`
- [ ] Markdown / Mermaid diagram - runs `markdownlint`

## Checklist

- [ ] I ran the linter for every area I touched and it passes locally
  - Bash: `shellcheck -S warning <file>`
  - Python: `ruff check <file>`
  - PowerShell: `Invoke-ScriptAnalyzer -Path <file> -Severity Error`
  - Markdown: `markdownlint-cli2 "**/*.md"`
- [ ] If I changed a script, I updated the relevant doc under `hypervisors/`,
      `virtual-machines/`, or `docs/` to reflect the new behavior
- [ ] If I added a new script, I added it to the matrix in
      `.github/workflows/ci.yml` (or explained why not below)
- [ ] I read `CONTRIBUTING.md` (if it exists)
- [ ] I did not commit any secrets, VM disks, or backup artifacts

## Verification

<!-- How did you test this? Screenshots / log snippets welcome. -->

## Notes

<!-- Anything reviewers should know about: design trade-offs, follow-up work, known limitations. -->
