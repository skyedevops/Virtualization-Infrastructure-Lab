<#
.SYNOPSIS
    Provisions a new Generation 2 lab VM with sensible defaults.

.DESCRIPTION
    Creates a Hyper-V Gen 2 VM with dynamic memory, multi-core vCPU, an attached
    install ISO, the correct boot order, integration services enabled, and
    production checkpoints. Idempotent: refuses to overwrite an existing VM.

.PARAMETER VMName
    Name of the VM. Used for VM folder and VHDX file name.

.PARAMETER CPU
    Number of virtual processors. Default: 2

.PARAMETER MemoryGB
    Startup memory in GB (dynamic min = half, max = double). Default: 4

.PARAMETER DiskGB
    Size of the OS VHDX in GB. Default: 60

.PARAMETER SwitchName
    Name of the virtual switch to attach the primary NIC to. Default: vSwitch-Internal

.PARAMETER IsoPath
    Optional ISO to mount as the install DVD.

.PARAMETER VMPath
    Override default VM storage root. Default: VMHost.VirtualMachinePath

.PARAMETER SecureBoot
    On / Off / Linux (MicrosoftUEFICertificateAuthority). Default: On

.PARAMETER NestedVirt
    Expose virtualization extensions to guest (for nested labs). Default: $false

.EXAMPLE
    .\New-LabVM.ps1 -VMName dc01 -CPU 4 -MemoryGB 4 -DiskGB 80 `
                    -SwitchName vSwitch-Internal `
                    -IsoPath D:\VMs\ISOs\WindowsServer2022.iso

.EXAMPLE
    .\New-LabVM.ps1 -VMName ubuntu-web01 -CPU 2 -MemoryGB 2 `
                    -SwitchName vSwitch-External -SecureBoot Linux `
                    -IsoPath D:\VMs\ISOs\ubuntu-22.04.4-live-server-amd64.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VMName,
    [int]    $CPU         = 2,
    [int]    $MemoryGB    = 4,
    [int]    $DiskGB      = 60,
    [string] $SwitchName  = "vSwitch-Internal",
    [string] $IsoPath,
    [string] $VMPath,
    [ValidateSet('On','Off','Linux')] [string] $SecureBoot = 'On',
    [switch] $NestedVirt
)

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

function Write-Step ($msg) { Write-Host "[+] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Choose a different name or remove the existing VM."
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$SwitchName' not found. Run Enable-HyperVRole.ps1 first."
}

if (-not $VMPath) { $VMPath = (Get-VMHost).VirtualMachinePath }
$vmFolder = Join-Path $VMPath $VMName
$vhdPath  = Join-Path $vmFolder "$VMName.vhdx"

Write-Step "Creating VM folder $vmFolder"
New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null

Write-Step "Creating VM '$VMName' (Gen 2, ${MemoryGB}GB RAM startup, ${CPU} vCPU, ${DiskGB}GB disk)"
$startupBytes = [int64]$MemoryGB * 1GB
New-VM -Name $VMName `
       -Generation 2 `
       -MemoryStartupBytes $startupBytes `
       -Path $VMPath `
       -NewVHDPath $vhdPath `
       -NewVHDSizeBytes ([int64]$DiskGB * 1GB) `
       -SwitchName $SwitchName | Out-Null

Write-Step "Setting processor count = $CPU (nested = $NestedVirt)"
Set-VMProcessor -VMName $VMName -Count $CPU `
                -ExposeVirtualizationExtensions:$NestedVirt.IsPresent

Write-Step "Configuring dynamic memory ($($MemoryGB/2)GB - ${MemoryGB}GB - $($MemoryGB*2)GB)"
Set-VMMemory -VMName $VMName `
             -DynamicMemoryEnabled $true `
             -MinimumBytes ([int64]($MemoryGB*0.5) * 1GB) `
             -StartupBytes $startupBytes `
             -MaximumBytes ([int64]($MemoryGB*2) * 1GB) `
             -Buffer 20

Write-Step "Enabling all integration services"
Get-VMIntegrationService -VMName $VMName | Enable-VMIntegrationService

Write-Step "Setting automatic actions and production checkpoints"
Set-VM -Name $VMName `
       -AutomaticStartAction StartIfRunning `
       -AutomaticStartDelay 30 `
       -AutomaticStopAction Save `
       -CheckpointType Production `
       -SnapshotFileLocation $vmFolder

# Secure Boot configuration
switch ($SecureBoot) {
    'Off'   { Set-VMFirmware -VMName $VMName -EnableSecureBoot Off }
    'Linux' { Set-VMFirmware -VMName $VMName -EnableSecureBoot On `
                             -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' }
    Default { Set-VMFirmware -VMName $VMName -EnableSecureBoot On }
}

# Mount ISO if provided and set boot order
if ($IsoPath) {
    if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }
    Write-Step "Attaching ISO $IsoPath"
    Add-VMDvdDrive -VMName $VMName -Path $IsoPath
    $dvd = Get-VMDvdDrive -VMName $VMName
    $hdd = Get-VMHardDiskDrive -VMName $VMName
    Set-VMFirmware -VMName $VMName -BootOrder $dvd, $hdd
}

# Optionally enable resource metering for sizing analysis
Enable-VMResourceMetering -VMName $VMName

Write-OK "VM '$VMName' provisioned."
Get-VM -Name $VMName | Format-List Name, State, ProcessorCount, MemoryStartup, Generation, Path
Write-Host "Start with:  Start-VM -Name $VMName" -ForegroundColor Magenta
Write-Host "Console:     vmconnect.exe localhost $VMName" -ForegroundColor Magenta
