<#
.SYNOPSIS
    PowerShell wrapper around scripts/python/labctl.py.

.DESCRIPTION
    Provides the same targets as the Makefile for Windows users.
    Requires Python 3.8+ on PATH (or in $env:LOCALAPPDATA\Programs\Python).

.EXAMPLE
    .\scripts\make.ps1 plan
    .\scripts\make.ps1 -Target drill -VM web01
    .\scripts\make.ps1 -Target migrate -VM pfsense -TargetNode pve02
    .\scripts\make.ps1 -Target ha-drill -Node pve01
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)] [ValidateSet(
        'help','validate','plan','apply','inventory','start','stop',
        'backup','drill','migrate','ha-status','ha-drill',
        'pbs-status','pbs-init','pbs-restore-test','clean')]
    [string] $Target = 'help',
    [string] $Lab = 'lab.yaml',
    [string] $VM,
    [string] $TargetNode,
    [string] $Node,
    [string] $Pbs,
    [string] $Datastore,
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
    'migrate' {
        if (-not $VM -or -not $TargetNode) {
            throw "migrate requires -VM and -TargetNode. Example: .\make.ps1 migrate -VM pfsense -TargetNode pve02"
        }
        $pyArgs += @('migrate', '--vm', $VM, '--target', $TargetNode, '--execute')
    }
    'ha-drill' {
        if (-not $Node) {
            throw "ha-drill requires -Node. Example: .\make.ps1 ha-drill -Node pve01"
        }
        $pyArgs += @('drill-ha-failover', '--node', $Node, '--execute', '--yes')
    }
    'pbs-init' {
        $pyArgs += @('pbs-init', '--execute')
    }
    'pbs-status' {
        $pyArgs += @('pbs-status')
    }
    'pbs-restore-test' {
        $extra = @('pbs-restore-test', '--execute')
        if ($Pbs)       { $extra += @('--pbs', $Pbs) }
        if ($Datastore) { $extra += @('--datastore', $Datastore) }
        $pyArgs += $extra
    }
    'help' {
        Write-Host "Targets: validate, plan, apply, inventory, start, stop, backup, drill, migrate, ha-status, ha-drill, pbs-status, pbs-init, pbs-restore-test, clean" -ForegroundColor Cyan
        Write-Host "Example:  .\make.ps1 plan"
        Write-Host "          .\make.ps1 drill -VM web01"
        Write-Host "          .\make.ps1 migrate -VM pfsense -TargetNode pve02"
        Write-Host "          .\make.ps1 ha-drill -Node pve01"
        Write-Host "          .\make.ps1 pbs-init"
        Write-Host "          .\make.ps1 pbs-restore-test -Pbs pbs01 -Datastore main"
        return
    }
    default { $pyArgs += $Target }
}

Write-Host "[$Target] running: $Python $($pyArgs -join ' ')" -ForegroundColor DarkGray
& $Python @pyArgs
exit $LASTEXITCODE
