<#
.SYNOPSIS
    Creates the three baseline lab virtual switches.

.DESCRIPTION
    Idempotent helper that creates External, Internal, and Private switches
    matching the lab topology. Safe to re-run; existing switches are skipped.

.PARAMETER ExternalNic
    Physical adapter name for the External switch. Default: first 'Up' Ethernet adapter.

.PARAMETER InternalSubnet
    IP/prefix assigned to the host vNIC on the Internal switch. Default: 10.10.20.1/24

.EXAMPLE
    .\New-VMSwitch-Lab.ps1
    .\New-VMSwitch-Lab.ps1 -ExternalNic "Ethernet 2" -InternalSubnet "192.168.50.1/24"
#>
[CmdletBinding()]
param(
    [string] $ExternalNic,
    [string] $InternalSubnet = "10.10.20.1/24"
)

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V, NetTCPIP

function Ensure-Switch ($name, $params, $note) {
    if (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue) {
        Write-Host "[=] $name already exists" -ForegroundColor DarkGray
    } else {
        New-VMSwitch -Name $name @params -Notes $note | Out-Null
        Write-Host "[+] Created $name" -ForegroundColor Green
    }
}

# External
if (-not $ExternalNic) {
    $ExternalNic = (Get-NetAdapter -Physical |
                    Where-Object Status -eq 'Up' |
                    Sort-Object ifIndex | Select-Object -First 1).Name
}
if ($ExternalNic) {
    Ensure-Switch "vSwitch-External" `
        @{ NetAdapterName = $ExternalNic; AllowManagementOS = $true } `
        "Lab External - LAN uplink ($ExternalNic)"
} else {
    Write-Warning "No physical NIC up - skipping External switch."
}

# Internal
Ensure-Switch "vSwitch-Internal" `
    @{ SwitchType = 'Internal' } `
    "Lab Internal - $InternalSubnet"

# Apply IP to host vNIC if not yet configured
$ip, $prefix = $InternalSubnet -split '/'
$ifIndex = (Get-NetAdapter -Name "vEthernet (vSwitch-Internal)" -ErrorAction SilentlyContinue).ifIndex
if ($ifIndex) {
    $existing = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $ip }
    if (-not $existing) {
        New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $ip -PrefixLength $prefix | Out-Null
        Write-Host "[+] Assigned $InternalSubnet to vSwitch-Internal host vNIC" -ForegroundColor Green
    }
}

# Private
Ensure-Switch "vSwitch-Private" `
    @{ SwitchType = 'Private' } `
    "Lab Private - isolated test bench"

Write-Host ""
Get-VMSwitch | Format-Table Name, SwitchType, NetAdapterInterfaceDescription, Notes -AutoSize
