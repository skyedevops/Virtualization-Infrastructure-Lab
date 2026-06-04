<#
.SYNOPSIS
    Enables Hyper-V role and applies lab-standard host configuration.

.DESCRIPTION
    One-shot script to install Hyper-V on Windows Server 2019/2022, configure
    default VM/VHD paths, enable enhanced session mode, and create the three
    baseline virtual switches used by the Virtualization & Infrastructure Lab.

.PARAMETER VMRoot
    Root directory for VM config files. Default: D:\VMs\Virtual Machines

.PARAMETER VHDRoot
    Root directory for virtual hard disks. Default: D:\VMs\Virtual Hard Disks

.PARAMETER ExternalNic
    Name of the physical NIC to bind to vSwitch-External. Default: first up Ethernet adapter.

.EXAMPLE
    .\Enable-HyperVRole.ps1 -VMRoot "E:\VMs" -VHDRoot "E:\VHDs"

.NOTES
    Run as Administrator. Reboot required after Hyper-V role install.
#>
[CmdletBinding()]
param(
    [string]$VMRoot      = "D:\VMs\Virtual Machines",
    [string]$VHDRoot     = "D:\VMs\Virtual Hard Disks",
    [string]$ExternalNic
)

#Requires -RunAsAdministrator
#Requires -Version 5.1

function Write-Step ($msg) { Write-Host "[+] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# 1. Install Hyper-V role
# -----------------------------------------------------------------------------
Write-Step "Checking Hyper-V role state..."
$feature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
if (-not $feature) {
    throw "Hyper-V feature not found. Are you on a Windows Server SKU?"
}

if ($feature.InstallState -ne 'Installed') {
    Write-Step "Installing Hyper-V role and management tools (reboot will be required)..."
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false | Out-Null
    Write-Warn "Hyper-V installed. Reboot, then re-run this script to finish configuration."
    return
}
Write-OK "Hyper-V role already installed."

# -----------------------------------------------------------------------------
# 2. Create storage directories
# -----------------------------------------------------------------------------
foreach ($p in @($VMRoot, $VHDRoot, "$(Split-Path $VMRoot)\Exports", "$(Split-Path $VMRoot)\ISOs")) {
    if (-not (Test-Path $p)) {
        Write-Step "Creating directory $p"
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 3. Configure VMHost
# -----------------------------------------------------------------------------
Write-Step "Setting default VM and VHD paths..."
Set-VMHost -VirtualMachinePath $VMRoot `
           -VirtualHardDiskPath $VHDRoot `
           -EnableEnhancedSessionMode $true `
           -NumaSpanningEnabled $true `
           -MaximumStorageMigrations 4 `
           -MaximumVirtualMachineMigrations 2

Write-OK "VMHost configured."

# -----------------------------------------------------------------------------
# 4. Create baseline virtual switches (idempotent)
# -----------------------------------------------------------------------------
Write-Step "Configuring baseline virtual switches..."

# External
if (-not (Get-VMSwitch -Name "vSwitch-External" -ErrorAction SilentlyContinue)) {
    if (-not $ExternalNic) {
        $ExternalNic = (Get-NetAdapter -Physical |
                        Where-Object Status -eq 'Up' |
                        Sort-Object ifIndex |
                        Select-Object -First 1).Name
    }
    if ($ExternalNic) {
        New-VMSwitch -Name "vSwitch-External" `
                     -NetAdapterName $ExternalNic `
                     -AllowManagementOS $true `
                     -Notes "Lab External - LAN uplink ($ExternalNic)" | Out-Null
        Write-OK "Created vSwitch-External on $ExternalNic"
    } else {
        Write-Warn "No physical NIC found - skipping vSwitch-External"
    }
} else {
    Write-OK "vSwitch-External already exists"
}

# Internal
if (-not (Get-VMSwitch -Name "vSwitch-Internal" -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name "vSwitch-Internal" -SwitchType Internal `
                 -Notes "Lab Internal - 10.10.20.0/24" | Out-Null
    Write-OK "Created vSwitch-Internal"
    # Assign IP to host adapter on internal switch
    $intAdapter = Get-NetAdapter -Name "vEthernet (vSwitch-Internal)" -ErrorAction SilentlyContinue
    if ($intAdapter) {
        New-NetIPAddress -InterfaceIndex $intAdapter.ifIndex `
                         -IPAddress 10.10.20.1 -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
    }
} else {
    Write-OK "vSwitch-Internal already exists"
}

# Private
if (-not (Get-VMSwitch -Name "vSwitch-Private" -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name "vSwitch-Private" -SwitchType Private `
                 -Notes "Lab Private - isolated test bench" | Out-Null
    Write-OK "Created vSwitch-Private"
} else {
    Write-OK "vSwitch-Private already exists"
}

# -----------------------------------------------------------------------------
# 5. Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "============= Host Summary =============" -ForegroundColor Magenta
Get-VMHost | Format-List Name, VirtualMachinePath, VirtualHardDiskPath, EnableEnhancedSessionMode
Get-VMSwitch | Format-Table Name, SwitchType, NetAdapterInterfaceDescription -AutoSize
Write-Host "Host ready. Provision VMs with .\New-LabVM.ps1" -ForegroundColor Magenta
