<#
.SYNOPSIS
    Bulk-start or bulk-stop tagged Hyper-V VMs in a defined order.

.DESCRIPTION
    Lab VMs typically have a startup order: DC -> DNS -> file -> apps -> clients.
    This script reads the tag/order from VM Notes (JSON snippet) and orchestrates
    a graceful start or stop.

    Example VM Notes:  {"startOrder": 10, "tag": "core"}

.PARAMETER Action
    Start | Stop

.PARAMETER Tag
    Optional tag filter (e.g. "core").

.PARAMETER WaitSeconds
    Seconds to wait between groups. Default: 30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Start','Stop')] [string] $Action,
    [string] $Tag,
    [int]    $WaitSeconds = 30
)

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

function Get-Meta($notes) {
    try { ConvertFrom-Json -InputObject $notes -ErrorAction Stop } catch { @{ startOrder = 999; tag = "" } }
}

$vms = Get-VM | ForEach-Object {
    $meta = Get-Meta $_.Notes
    $_ | Add-Member -NotePropertyName StartOrder -NotePropertyValue ([int]$meta.startOrder) -PassThru |
         Add-Member -NotePropertyName Tag        -NotePropertyValue ([string]$meta.tag)    -PassThru
}

if ($Tag) { $vms = $vms | Where-Object Tag -eq $Tag }
$vms = $vms | Sort-Object StartOrder

if (-not $vms) { Write-Warning "No VMs matched."; return }

if ($Action -eq 'Stop') { [array]::Reverse($vms) }

$prevOrder = -1
foreach ($vm in $vms) {
    if ($prevOrder -ne -1 -and $vm.StartOrder -ne $prevOrder) {
        Write-Host "[..] Waiting $WaitSeconds s before next group..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $WaitSeconds
    }
    Write-Host "[$Action] $($vm.Name) (order=$($vm.StartOrder), tag=$($vm.Tag))" -ForegroundColor Cyan
    if ($Action -eq 'Start') {
        if ($vm.State -ne 'Running') { Start-VM -Name $vm.Name }
    } else {
        if ($vm.State -eq 'Running') { Stop-VM -Name $vm.Name -Force:$false }
    }
    $prevOrder = $vm.StartOrder
}
Write-Host "[OK] Done." -ForegroundColor Green
