<#
.SYNOPSIS
    PowerShell wrapper around scripts/python/labctl.py.

.DESCRIPTION
    Provides the same targets as the Makefile for Windows users.
    Requires Python 3.8+ on PATH (or in $env:LOCALAPPDATA\Programs\Python).

.EXAMPLE
    .\scripts\make.ps1 plan
    .\scripts\make.ps1 -Target drill -VM web01
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)] [ValidateSet('help','validate','plan','apply','inventory','start','stop','backup','drill','clean')]
    [string] $Target = 'help',
    [string] $Lab = 'lab.yaml',
    [string] $VM,
    [string] $Python = 'python'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
$labCtl   = Join-Path $repoRoot 'scripts/python/labctl.py'

if (-not (Test-Path $labCtl)) { throw "labctl.py not found at $labCtl" }
if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
    throw "Python not found on PATH. Install Python 3.8+ or pass -Python 'C:\Path\To\python.exe'"
}

$pyArgs = @($labCtl, '--lab', $Lab)
switch ($Target) {
    'drill' {
        if (-not $VM) { throw "drill requires -VM. Example: .\make.ps1 drill -VM web01" }
        $pyArgs += @('drill', '--vm', $VM)
    }
    'help' {
        Write-Host "Targets: validate, plan, apply, inventory, start, stop, backup, drill, clean" -ForegroundColor Cyan
        Write-Host "Example:  .\make.ps1 plan"
        Write-Host "          .\make.ps1 drill -VM web01"
        return
    }
    default { $pyArgs += $Target }
}

Write-Host "[$Target] running: $Python $($pyArgs -join ' ')" -ForegroundColor DarkGray
& $Python @pyArgs
exit $LASTEXITCODE
