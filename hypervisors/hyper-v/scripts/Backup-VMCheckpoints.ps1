<#
.SYNOPSIS
    Takes a checkpoint of each VM and exports VMs to a backup directory.

.DESCRIPTION
    Implements the daily checkpoint + weekly export strategy used by the lab.
    - Always creates a production checkpoint with timestamped name.
    - Prunes checkpoints older than -RetainDays (default 7).
    - On the configured -FullExportDay (default Sunday), exports each VM to
      -ExportPath for offline / off-site backup.

.PARAMETER VMName
    Optional VM name filter (wildcards allowed). Default: all VMs.

.PARAMETER ExportPath
    Destination directory for full exports. Default: D:\VMs\Exports

.PARAMETER RetainDays
    Number of days of checkpoints to retain. Default: 7

.PARAMETER FullExportDay
    Day of week to run a full export. Default: Sunday

.EXAMPLE
    .\Backup-VMCheckpoints.ps1
    .\Backup-VMCheckpoints.ps1 -VMName "dc*" -RetainDays 14
#>
[CmdletBinding()]
param(
    [string] $VMName        = "*",
    [string] $ExportPath    = "D:\VMs\Exports",
    [int]    $RetainDays    = 7,
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string] $FullExportDay = 'Sunday'
)

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

$ErrorActionPreference = 'Stop'
$today    = Get-Date
$stamp    = $today.ToString('yyyyMMdd-HHmmss')
$logRoot  = Join-Path $ExportPath "logs"
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$logFile  = Join-Path $logRoot "backup-$stamp.log"

function Log ($msg) {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

$vms = Get-VM | Where-Object { $_.Name -like $VMName }
if (-not $vms) { Log "No VMs matched '$VMName'"; return }

Log "Backup run started. Targets: $($vms.Name -join ', ')"
Log "Export path: $ExportPath  |  Retention: $RetainDays days  |  Full export on $FullExportDay"

$doFullExport = ($today.DayOfWeek -eq $FullExportDay)
Log "Full export today? $doFullExport"

foreach ($vm in $vms) {
    $name = $vm.Name
    Log "----- $name -----"

    # 1. Production checkpoint (app-consistent on Win, file-system-consistent on Linux w/ VSS)
    $snapName = "auto-$stamp"
    try {
        Checkpoint-VM -Name $name -SnapshotName $snapName
        Log "Checkpoint created: $snapName"
    } catch {
        Log "ERROR creating checkpoint: $_"
        continue
    }

    # 2. Prune old auto-checkpoints
    $cutoff = $today.AddDays(-$RetainDays)
    $old = Get-VMSnapshot -VMName $name |
           Where-Object { $_.Name -like 'auto-*' -and $_.CreationTime -lt $cutoff }
    foreach ($s in $old) {
        try {
            Remove-VMSnapshot -VMName $name -Name $s.Name -Confirm:$false
            Log "Pruned old checkpoint: $($s.Name) ($($s.CreationTime))"
        } catch {
            Log "WARN failed to prune $($s.Name): $_"
        }
    }

    # 3. Weekly full export
    if ($doFullExport) {
        $dest = Join-Path $ExportPath ("{0}_{1}" -f $name, $today.ToString('yyyyMMdd'))
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        try {
            Log "Exporting $name to $dest ..."
            Export-VM -Name $name -Path $ExportPath
            Rename-Item -Path (Join-Path $ExportPath $name) -NewName (Split-Path $dest -Leaf)
            Log "Export complete."
        } catch {
            Log "ERROR exporting ${name}: $_"
        }

        # Trim old exports - keep last 4 weeks
        $exports = Get-ChildItem -Path $ExportPath -Directory |
                   Where-Object { $_.Name -like "$name`_*" } |
                   Sort-Object CreationTime -Descending
        if ($exports.Count -gt 4) {
            $exports | Select-Object -Skip 4 | ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force
                Log "Pruned old export: $($_.Name)"
            }
        }
    }
}

Log "Backup run complete. Log: $logFile"
