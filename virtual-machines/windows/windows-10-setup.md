# Windows 10 / 11 Pro - Client VM Build

Reference build for client OS test VMs (RSAT admin workstation, software compatibility testing, end-user shadowing).

## Build Specs

| Spec | Value |
|------|-------|
| OS | Windows 10 22H2 Pro / Windows 11 23H2 Pro |
| Disk | 60 GB |
| RAM | 4 GB (Win10) / 8 GB (Win11) |
| vCPU | 2 |
| Boot | UEFI + Secure Boot (mandatory for Win11) |
| TPM | vTPM 2.0 (mandatory for Win11) |
| Account | Local admin, no MS account |

## 1. Installer Bypasses (Win11 only)

If installing Win11 on a VM that doesn't meet stock requirements (older CPU, no TPM exposed):

At the "This PC can't run Windows 11" screen:

1. Press **Shift+F10** to open a command prompt.
2. Type `regedit`, then create:
   - `HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig`
     - DWORD `BypassTPMCheck` = `1`
     - DWORD `BypassSecureBootCheck` = `1`
     - DWORD `BypassRAMCheck` = `1`
3. Close regedit, click **Back**, retry install.

To bypass the **online account requirement** on Win11 OOBE:

- At the network screen press **Shift+F10** -> `OOBE\BYPASSNRO` -> machine reboots -> choose "I don't have internet" -> "Continue with limited setup" -> create local account.

## 2. First-Boot PowerShell Tasks

```powershell
# Rename + reboot
Rename-Computer -NewName "win11-admin01" -Restart

# Timezone + Windows Update
Set-TimeZone -Name "UTC"
Install-Module PSWindowsUpdate -Force -Confirm:$false
Install-WindowsUpdate -AcceptAll -AutoReboot

# Disable telemetry-heavy bits
Get-Service DiagTrack | Stop-Service -Force
Set-Service -Name DiagTrack -StartupType Disabled

# Remove bundled bloat (Win11 examples)
$apps = @(
  'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp',
  'Microsoft.Getstarted','Microsoft.MicrosoftSolitaireCollection',
  'Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
  'Microsoft.WindowsFeedbackHub','Microsoft.MixedReality.Portal'
)
foreach ($a in $apps) {
  Get-AppxPackage -Name $a -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
  Get-AppxProvisionedPackage -Online | Where-Object DisplayName -EQ $a | Remove-AppxProvisionedPackage -Online
}
```

## 3. Install RSAT (Admin Tools)

```powershell
Get-WindowsCapability -Name RSAT* -Online | `
  Where-Object State -ne Installed | `
  Add-WindowsCapability -Online
```

Now Active Directory Users & Computers, DNS, DHCP, Hyper-V Manager, etc., are available on the client.

## 4. Join the Lab Domain

```powershell
Add-Computer -DomainName "lab.local" `
             -Credential (Get-Credential LAB\labadmin) `
             -Restart
```

## 5. Install Standard Developer / Admin Tools (winget)

```powershell
winget install --id Microsoft.PowerShell                 -e
winget install --id Microsoft.WindowsTerminal            -e
winget install --id Git.Git                              -e
winget install --id Microsoft.VisualStudioCode           -e
winget install --id Microsoft.Sysinternals.Suite         -e
winget install --id WiresharkFoundation.Wireshark        -e
winget install --id Putty.Putty                          -e
winget install --id 7zip.7zip                            -e
winget install --id Mozilla.Firefox                      -e
```

## 6. BitLocker (optional)

```powershell
Enable-BitLocker -MountPoint "C:" `
                 -EncryptionMethod XtsAes256 `
                 -UsedSpaceOnly `
                 -TpmProtector
Add-BitLockerKeyProtector -MountPoint "C:" -RecoveryPasswordProtector
manage-bde -protectors -get C:
```

> Recovery key is written to AD if the host is domain-joined (with the right GPO) - test recovery before relying on it.

## 7. Snapshot

Take `clean-baseline` at the hypervisor level after patching and domain join.
