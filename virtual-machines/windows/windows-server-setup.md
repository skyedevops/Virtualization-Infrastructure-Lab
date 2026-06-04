# Windows Server 2022 - Standard Build

Reference Windows guest build used across all four hypervisors in this lab. The same procedure applies to Windows Server 2019; for Windows 10/11 client builds see [windows-10-setup.md](windows-10-setup.md).

## Build Specs

| Spec | Value |
|------|-------|
| OS | Windows Server 2022 Standard (Desktop Experience) |
| Disk | 80 GB VHDX / VMDK (dynamic) |
| RAM | 4-8 GB (dynamic where supported) |
| vCPU | 2-4 |
| Boot | UEFI + Secure Boot |
| TPM | vTPM enabled (Hyper-V Shielded / VMware vTPM / Proxmox tpmstate) |
| Time | Windows Time service against pool.ntp.org |
| Patching | WSUS or Windows Update via group policy |

## 1. Installation

1. Boot the install ISO.
2. Language / keyboard -> defaults.
3. **Install Now**.
4. Edition: **Windows Server 2022 Standard (Desktop Experience)** for full GUI. Pick "Core" for headless.
5. License terms -> accept.
6. **Custom: Install Windows only**.
7. Partition: select unallocated -> **New** -> apply -> Next.
   - Installer auto-creates EFI / MSR / Recovery / OS partitions.
8. Wait for install + reboots.
9. Set Administrator password. Use a strong passphrase; store in your password manager.

## 2. First-Boot Configuration (PowerShell)

```powershell
# Rename + reboot
Rename-Computer -NewName "dc01" -Restart

# After reboot, set timezone + sync
Set-TimeZone -Name "UTC"
w32tm /config /manualpeerlist:"pool.ntp.org,0x9" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time
w32tm /resync

# Set static IP
$ifAlias = (Get-NetAdapter | Where-Object Status -eq 'Up')[0].Name
New-NetIPAddress -InterfaceAlias $ifAlias `
                 -IPAddress 10.10.20.10 -PrefixLength 24 `
                 -DefaultGateway 10.10.20.1
Set-DnsClientServerAddress -InterfaceAlias $ifAlias `
                           -ServerAddresses 127.0.0.1,1.1.1.1

# Enable Remote Desktop
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                 -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Enable PSRemoting
Enable-PSRemoting -Force
Set-Item WSMan:\localhost\Service\AllowUnencrypted $false
```

## 3. Install Updates

```powershell
Install-Module PSWindowsUpdate -Force -Confirm:$false
Import-Module PSWindowsUpdate
Get-WindowsUpdate
Install-WindowsUpdate -AcceptAll -AutoReboot
```

## 4. Promote to Domain Controller (optional, for `dc01`)

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

Install-ADDSForest `
  -DomainName "lab.local" `
  -DomainNetbiosName "LAB" `
  -ForestMode WinThreshold `
  -DomainMode WinThreshold `
  -InstallDns `
  -DatabasePath  "C:\NTDS" `
  -LogPath       "C:\NTDS" `
  -SysvolPath    "C:\SYSVOL" `
  -SafeModeAdministratorPassword (Read-Host -AsSecureString "DSRM password") `
  -Force
# Server reboots automatically into a DC role
```

After reboot:

```powershell
# Validate
Get-ADForest
Get-ADDomain
Get-ADDomainController

# Install DHCP role
Install-WindowsFeature -Name DHCP -IncludeManagementTools
Add-DhcpServerInDC
Add-DhcpServerv4Scope -Name "Clients" `
  -StartRange 10.10.30.100 -EndRange 10.10.30.250 `
  -SubnetMask 255.255.255.0 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.30.0 `
  -Router 10.10.30.1 -DnsServer 10.10.20.10 -DnsDomain "lab.local"
```

## 5. Hardening Baseline

```powershell
# Disable SMBv1
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Confirm:$false

# Disable LLMNR (LSA leak prevention)
New-Item "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient" -Force
New-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient" `
  -Name "EnableMulticast" -Value 0 -PropertyType DWORD -Force

# Enforce SMB signing
Set-SmbServerConfiguration -RequireSecuritySignature $true -Confirm:$false

# Disable IPv6 if not used (optional)
Disable-NetAdapterBinding -Name $ifAlias -ComponentID ms_tcpip6

# Block known-bad LAN protocols via firewall
New-NetFirewallRule -DisplayName "Block-NetBIOS" -Direction Inbound -Protocol UDP -LocalPort 137,138 -Action Block
New-NetFirewallRule -DisplayName "Block-NetBIOS" -Direction Inbound -Protocol TCP -LocalPort 139 -Action Block

# Enable Windows Defender + Controlled Folder Access
Set-MpPreference -EnableControlledFolderAccess Enabled
Set-MpPreference -PUAProtection Enabled
```

## 6. Hypervisor Integration

| Hypervisor | What to install |
|------------|-----------------|
| Hyper-V | Integration Services are bundled - just enable in VM settings |
| VMware Workstation | VM menu -> Install VMware Tools -> `setup64.exe` |
| Proxmox / KVM | Mount `virtio-win.iso`, install Balloon, NetKVM, vioscsi drivers, `qemu-ga-x64.msi` |
| VirtualBox | Devices -> Insert Guest Additions CD image -> `VBoxWindowsAdditions.exe` |

## 7. Baseline Snapshot

Take a hypervisor-level snapshot named `clean-baseline` once the server is patched, configured, and joined to the domain (if applicable).

## 8. Sysprep for Templating

```powershell
# From an elevated PowerShell:
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:C:\unattend.xml
```

Sample minimal `unattend.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral"
               versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>
      <TimeZone>UTC</TimeZone>
      <UserAccounts>
        <AdministratorPassword>
          <Value>Pa55w0rd!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
```
