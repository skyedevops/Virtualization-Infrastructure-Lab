<#
.SYNOPSIS
    Inventory all Hyper-V VMs on the local host and emit a CSV report.

.DESCRIPTION
    Collects power state, vCPU, RAM, disk usage, switch, IPs and uptime for
    every VM on the local Hyper-V host. Useful for tracking lab drift and
    quarterly resource reviews.

.PARAMETER OutFile
    CSV output path. Default: .\hyperv-inventory-YYYYMMDD.csv
#>
[CmdletBinding()]
param(
    [string] $OutFile = ".\hyperv-inventory-$(Get-Date -f yyyyMMdd).csv"
)

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

$rows = foreach ($vm in Get-VM) {
    $vhds = Get-VHD -VMId $vm.Id -ErrorAction SilentlyContinue
    $diskGB = if ($vhds) { [Math]::Round(($vhds | Measure-Object FileSize -Sum).Sum / 1GB, 1) } else { 0 }
    $diskMaxGB = if ($vhds) { [Math]::Round(($vhds | Measure-Object Size -Sum).Sum / 1GB, 1) } else { 0 }
    $nic = Get-VMNetworkAdapter -VMName $vm.Name | Select-Object -First 1
    $ips = ($nic.IPAddresses | Where-Object {$_ -notmatch '^fe80|^169\.254'}) -join ','

    [pscustomobject]@{
        Name        = $vm.Name
        State       = $vm.State
        Gen         = $vm.Generation
        vCPU        = $vm.ProcessorCount
        StartupGB   = [Math]::Round($vm.MemoryStartup / 1GB, 1)
        DynamicMem  = $vm.DynamicMemoryEnabled
        DiskUsedGB  = $diskGB
        DiskMaxGB   = $diskMaxGB
        Switch      = $nic.SwitchName
        IPs         = $ips
        Uptime      = $vm.Uptime
        CheckpointType = $vm.CheckpointType
        AutoStart   = $vm.AutomaticStartAction
        Path        = $vm.Path
    }
}

$rows | Sort-Object Name | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
Write-Host "[OK] Wrote $($rows.Count) rows to $OutFile" -ForegroundColor Green
$rows | Format-Table Name, State, vCPU, StartupGB, DiskUsedGB, DiskMaxGB, Switch, IPs -AutoSize
