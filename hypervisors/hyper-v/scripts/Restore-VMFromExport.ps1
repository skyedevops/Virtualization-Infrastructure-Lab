<#
.SYNOPSIS
    Imports a previously exported Hyper-V VM as a new instance.

.DESCRIPTION
    Recovery procedure for VMs backed up via Backup-VMCheckpoints.ps1
    (Export-VM). Optionally renames the restored VM and re-attaches to a
    target switch.

.PARAMETER ExportFolder
    Path to the exported VM folder (e.g. D:\VMs\Exports\dc01_20260101).

.PARAMETER NewVMName
    Optional new name for the restored VM. Default: original name.

.PARAMETER SwitchName
    Switch to re-attach to. Default: same as exported VM (will fail if missing).

.PARAMETER CopyFiles
    If set, copies VHDX/config files to default VM path rather than registering
    in place. Recommended for restore-to-different-host scenarios.

.EXAMPLE
    .\Restore-VMFromExport.ps1 -ExportFolder D:\VMs\Exports\dc01_20260101 -CopyFiles

.EXAMPLE
    .\Restore-VMFromExport.ps1 -ExportFolder D:\VMs\Exports\dc01_20260101 `
                               -NewVMName dc01-restored -SwitchName vSwitch-Internal -CopyFiles
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ExportFolder,
    [string] $NewVMName,
    [string] $SwitchName,
    [switch] $CopyFiles
)

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ExportFolder)) { throw "Export folder not found: $ExportFolder" }

# Find the .vmcx config file
$vmcx = Get-ChildItem -Path $ExportFolder -Recurse -Filter "*.vmcx" | Select-Object -First 1
if (-not $vmcx) { throw "No .vmcx config file found under $ExportFolder" }
Write-Host "[+] Found VM config: $($vmcx.FullName)" -ForegroundColor Cyan

# Compare-VM lets us inspect/repair before final import
$report = Compare-VM -Path $vmcx.FullName -Copy:$CopyFiles -GenerateNewId
if ($report.Incompatibilities.Count -gt 0) {
    Write-Host "[!] Compatibility issues detected:" -ForegroundColor Yellow
    $report.Incompatibilities | Format-Table Source, Message -AutoSize

    # Common auto-fixes
    foreach ($issue in $report.Incompatibilities) {
        switch ($issue.MessageId) {
            33012 {
                # Switch missing
                if ($SwitchName) {
                    Write-Host "[+] Reassigning NIC to switch '$SwitchName'" -ForegroundColor Cyan
                    $issue.Source | Connect-VMNetworkAdapter -SwitchName $SwitchName
                } else {
                    Write-Host "[!] No -SwitchName provided; disconnecting NIC" -ForegroundColor Yellow
                    $issue.Source | Disconnect-VMNetworkAdapter
                }
            }
            default {
                Write-Host "[!] Unhandled issue ID $($issue.MessageId): $($issue.Message)" -ForegroundColor Yellow
            }
        }
    }
}

# Rename if requested
if ($NewVMName) {
    $report.VM.Name = $NewVMName
    Write-Host "[+] Renaming restored VM to '$NewVMName'" -ForegroundColor Cyan
}

# Final import
$imported = Import-VM -CompatibilityReport $report
Write-Host "[OK] Import complete." -ForegroundColor Green
$imported | Format-List Name, State, Path, ProcessorCount, MemoryStartup

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Magenta
Write-Host "  Start-VM -Name '$($imported.Name)'"
Write-Host "  vmconnect.exe localhost '$($imported.Name)'"
