<#
.SYNOPSIS
    Idempotent Windows guest VM post-install baseline.

.DESCRIPTION
    Standardizes a freshly-installed Windows Server / Windows client VM:
    hostname, timezone, static IP, RDP, PSRemoting, basic hardening,
    Windows Updates, and an optional domain join.

.PARAMETER ComputerName
.PARAMETER IPAddress
.PARAMETER PrefixLength
.PARAMETER Gateway
.PARAMETER DnsServers
.PARAMETER InterfaceAlias
    Specific NIC alias. Default: first 'Up' adapter.
.PARAMETER DomainName
    Optional: AD domain to join.
.PARAMETER DomainCredential
    PSCredential for the domain join (LAB\labadmin).
.PARAMETER InstallUpdates
    Run Windows Updates after baseline. Default: $true

.EXAMPLE
    .\windows-vm-postinstall.ps1 -ComputerName web01 `
        -IPAddress 10.10.20.30 -PrefixLength 24 -Gateway 10.10.20.1 `
        -DnsServers 10.10.20.10,1.1.1.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $ComputerName,
    [Parameter(Mandatory)] [string]   $IPAddress,
    [int]                  $PrefixLength = 24,
    [Parameter(Mandatory)] [string]   $Gateway,
    [Parameter(Mandatory)] [string[]] $DnsServers,
    [string]                          $InterfaceAlias,
    [string]                          $DomainName,
    [pscredential]                    $DomainCredential,
    [bool]                            $InstallUpdates = $true
)

#Requires -RunAsAdministrator
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "[+] $m" -ForegroundColor Cyan }
function OK  ($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

Step "Timezone -> UTC"
Set-TimeZone -Id "UTC"
w32tm /config /manualpeerlist:"pool.ntp.org,0x9" /syncfromflags:manual /update | Out-Null
Restart-Service w32time
OK "Time configured"

if (-not $InterfaceAlias) {
    $InterfaceAlias = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
    if (-not $InterfaceAlias) { throw "No 'Up' network adapter found." }
}

Step "Configuring NIC '$InterfaceAlias' -> $IPAddress/$PrefixLength gw $Gateway"
# Remove existing IPv4 addresses + default route on this NIC
Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {$_.PrefixOrigin -eq 'Manual'} |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceAlias $InterfaceAlias -ErrorAction SilentlyContinue |
    Where-Object DestinationPrefix -eq '0.0.0.0/0' |
    Remove-NetRoute -Confirm:$false

New-NetIPAddress -InterfaceAlias $InterfaceAlias `
                 -IPAddress $IPAddress -PrefixLength $PrefixLength `
                 -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $DnsServers
OK "NIC configured"

Step "Enable RDP + firewall rule"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                 -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
OK "RDP enabled"

Step "Enable PSRemoting"
Enable-PSRemoting -Force | Out-Null
Set-Item WSMan:\localhost\Service\AllowUnencrypted $false
OK "PSRemoting enabled"

Step "Hardening - disable SMBv1, enforce signing, kill LLMNR"
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Confirm:$false
Set-SmbServerConfiguration -RequireSecuritySignature $true -Confirm:$false
$llmnrKey = "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient"
if (-not (Test-Path $llmnrKey)) { New-Item -Path $llmnrKey -Force | Out-Null }
New-ItemProperty -Path $llmnrKey -Name "EnableMulticast" -Value 0 -PropertyType DWORD -Force | Out-Null
OK "Hardening applied"

if ($InstallUpdates) {
    Step "Installing PSWindowsUpdate + running Windows Update"
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Install-PackageProvider NuGet -Force -Scope AllUsers | Out-Null
        Install-Module PSWindowsUpdate -Force -Confirm:$false
    }
    Import-Module PSWindowsUpdate
    try {
        Get-WindowsUpdate -AcceptAll -Install -AutoReboot:$false | Out-Host
        OK "Windows Update complete (reboot may be required)"
    } catch {
        Warn "Windows Update failed: $_"
    }
}

# Rename + reboot (and optional domain join)
if ($ComputerName -ne (Get-CimInstance Win32_ComputerSystem).Name) {
    if ($DomainName -and $DomainCredential) {
        Step "Renaming to $ComputerName AND joining domain $DomainName"
        Add-Computer -ComputerName $env:COMPUTERNAME `
                     -NewName $ComputerName `
                     -DomainName $DomainName `
                     -Credential $DomainCredential `
                     -Force -Restart
    } else {
        Step "Renaming to $ComputerName"
        Rename-Computer -NewName $ComputerName -Force -Restart
    }
} elseif ($DomainName -and $DomainCredential) {
    Step "Joining domain $DomainName"
    Add-Computer -DomainName $DomainName -Credential $DomainCredential -Force -Restart
} else {
    Write-Host ""
    OK "Baseline complete. Reboot recommended."
}
