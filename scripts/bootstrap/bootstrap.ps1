<#
.SYNOPSIS
    Turn a fresh Windows Server 2022 install into a working Hyper-V lab host.

.DESCRIPTION
    Run this on the Hyper-V host itself, as Administrator, after the
    Windows Server installer has finished and a management IP is set.

    What it does (idempotent):
      1. Enables the Hyper-V role + management tools
      2. Configures the default VM and VHD paths to a data drive
      3. Creates the three baseline vSwitches (External, Internal, Private)
      4. Installs Python 3 (if missing)
      5. Clones the lab repo to C:\lab
      6. Optionally runs labctl.py apply against this host

.PARAMETER Repo
    Git URL of the lab repo. Default: GitHub origin.

.PARAMETER Branch
    Branch to track. Default: main.

.PARAMETER LabPath
    Where to clone the repo. Default: C:\lab

.PARAMETER ExternalNic
    Physical NIC name for the External vSwitch. Default: first up Ethernet.

.PARAMETER VmPath
    Default VM config root. Default: D:\VMs\Virtual Machines

.PARAMETER VhdPath
    Default VHDX root. Default: D:\VMs\Virtual Hard Disks

.PARAMETER IsoPath
    Where ISOs live. Default: D:\ISOs

.PARAMETER Apply
    Run labctl.py apply after bootstrap. Default: $false

.EXAMPLE
    PS> .\scripts\bootstrap\bootstrap.ps1
    PS> .\scripts\bootstrap\bootstrap.ps1 -Apply

.NOTES
    Requires: Windows Server 2019/2022, Admin shell, internet access
#>
[CmdletBinding()]
param(
    [string] $Repo         = 'https://github.com/skyedevops/Virtualization-Infrastructure-Lab.git',
    [string] $Branch       = 'main',
    [string] $LabPath      = 'C:\lab',
    [string] $ExternalNic,
    [string] $VmPath       = 'D:\VMs\Virtual Machines',
    [string] $VhdPath      = 'D:\VMs\Virtual Hard Disks',
    [string] $IsoPath      = 'D:\ISOs',
    [switch] $Apply
)

#Requires -RunAsAdministrator
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'Continue'

function Step($m) { Write-Host "[+] $m" -ForegroundColor Cyan }
function OK  ($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[FATAL] $m" -ForegroundColor Red; exit 1 }

# -----------------------------------------------------------------------------
# 0. Pre-flight
# -----------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
Step "OS: $($os.Caption) $($os.Version)"
if ($os.ProductType -ne 2 -and $os.ProductType -ne 1) {
    Fail "Expected Windows Server or Windows Pro/Enterprise (ProductType 1 or 2), got $($os.ProductType)"
}

# -----------------------------------------------------------------------------
# 1. Hyper-V role
# -----------------------------------------------------------------------------
$feature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
if (-not $feature) {
    Fail "Hyper-V feature not available on this SKU"
}
if ($feature.InstallState -ne 'Installed') {
    Step "Installing Hyper-V role (reboot required)"
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    Warn "Hyper-V installed. Reboot, then re-run this script."
    exit 0
}
OK "Hyper-V already installed"

# -----------------------------------------------------------------------------
# 2. Storage layout
# -----------------------------------------------------------------------------
foreach ($p in @($VmPath, $VhdPath, $IsoPath, "$VmPath\..\Exports")) {
    if (-not (Test-Path $p)) {
        Step "Creating $p"
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 3. VMHost defaults
# -----------------------------------------------------------------------------
Step "Configuring VMHost defaults"
Set-VMHost -VirtualMachinePath $VmPath `
           -VirtualHardDiskPath $VhdPath `
           -EnableEnhancedSessionMode $true `
           -NumaSpanningEnabled $true | Out-Null
OK "VMHost: VM=$VmPath  VHD=$VhdPath"

# -----------------------------------------------------------------------------
# 4. vSwitches
# -----------------------------------------------------------------------------
Step "Ensuring vSwitches"
if (-not (Get-VMSwitch -Name 'vSwitch-External' -ErrorAction SilentlyContinue)) {
    if (-not $ExternalNic) {
        $ExternalNic = (Get-NetAdapter -Physical |
                        Where-Object Status -eq 'Up' |
                        Sort-Object ifIndex |
                        Select-Object -First 1).Name
    }
    if ($ExternalNic) {
        New-VMSwitch -Name 'vSwitch-External' `
                     -NetAdapterName $ExternalNic `
                     -AllowManagementOS $true | Out-Null
        OK "Created vSwitch-External on $ExternalNic"
    } else {
        Warn "No physical NIC up - skipping vSwitch-External"
    }
} else { OK "vSwitch-External exists" }

if (-not (Get-VMSwitch -Name 'vSwitch-Internal' -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name 'vSwitch-Internal' -SwitchType Internal | Out-Null
    $vif = Get-NetAdapter -Name 'vEthernet (vSwitch-Internal)' -ErrorAction SilentlyContinue
    if ($vif) {
        New-NetIPAddress -InterfaceIndex $vif.ifIndex -IPAddress 10.10.20.1 -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
    }
    OK "Created vSwitch-Internal"
} else { OK "vSwitch-Internal exists" }

if (-not (Get-VMSwitch -Name 'vSwitch-Private' -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name 'vSwitch-Private' -SwitchType Private | Out-Null
    OK "Created vSwitch-Private"
} else { OK "vSwitch-Private exists" }

# -----------------------------------------------------------------------------
# 5. Python
# -----------------------------------------------------------------------------
Step "Ensuring Python 3.11+"
$py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if (-not $py) {
    Warn "Python not found. Install via 'winget install Python.Python.3.12' and re-run."
    Warn "Bootstrap continuing without labctl."
} else {
    OK "Python: $py"
    & python -m pip install --upgrade pip --quiet
    & python -m pip install pyyaml --quiet
    OK "PyYAML installed"
}

# -----------------------------------------------------------------------------
# 6. Git
# -----------------------------------------------------------------------------
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    Warn "Git not found. Install via 'winget install Git.Git' and re-run."
}

# -----------------------------------------------------------------------------
# 7. Clone the lab repo
# -----------------------------------------------------------------------------
if (-not (Test-Path $LabPath)) {
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        Step "Cloning $Repo -> $LabPath"
        git clone --depth 1 --branch $Branch $Repo $LabPath
        OK "Lab repo cloned"
    } else {
        Warn "Skipping clone (no git). Manually clone to $LabPath."
    }
} else {
    Step "Updating $LabPath"
    Push-Location $LabPath
    try { git pull --ff-only } catch { Warn "Pull failed: $_" }
    Pop-Location
}

# -----------------------------------------------------------------------------
# 8. Apply lab.yaml
# -----------------------------------------------------------------------------
if ($Apply -and (Test-Path "$LabPath\lab.yaml")) {
    Step "Running labctl apply against this host"
    Push-Location $LabPath
    try {
        # Detect the local hypervisor entry: one whose host is this IP
        $ip = (Get-NetIPAddress -AddressFamily IPv4 |
               Where-Object {$_.IPAddress -notmatch '^(127\.|169\.254\.)'} |
               Select-Object -First 1).IPAddress
        $localHv = $null
        if ($ip) {
            $matches = Select-String -Path .\lab.yaml -Pattern "host:\s+$([regex]::Escape($ip))" -SimpleMatch:$false
            # Cheap scan: just find the hypervisor whose host matches
            $hvBlocks = (Get-Content .\lab.yaml -Raw) -split "`n`n"
            foreach ($block in $hvBlocks) {
                if ($block -match "(?m)^hypervisors:" -or $block -match "(?m)^vms:") { continue }
                if ($block -match "host:\s+$([regex]::Escape($ip))") {
                    if ($block -match "(?m)^  (\w+):") {
                        $localHv = $Matches[1]
                        break
                    }
                }
            }
        }
        if ($localHv) {
            Step "Local hypervisor: $localHv"
            python scripts/python/labctl.py apply --hypervisor $localHv
        } else {
            Warn "No hypervisor in lab.yaml targets $ip. Skipping apply."
        }
    } finally { Pop-Location }
} else {
    Step "Skipping apply. To provision VMs, re-run with -Apply"
}

# -----------------------------------------------------------------------------
# 9. Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "========== Bootstrap complete ==========" -ForegroundColor Magenta
Write-Host "Lab repo: $LabPath"
Write-Host "VM root : $VmPath"
Write-Host "VHD root: $VhdPath"
Write-Host "ISO root: $IsoPath"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Magenta
Write-Host "  cd $LabPath"
Write-Host "  python scripts\python\labctl.py validate"
Write-Host "  python scripts\python\labctl.py inventory"
Write-Host "  python scripts\python\labctl.py plan"
Write-Host "  python scripts\python\labctl.py apply --execute --yes"
