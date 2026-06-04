# Hyper-V - VM Configuration

This guide covers Generation 2 VM creation, the recommended type for modern guests (UEFI, Secure Boot, no legacy emulation, faster boot, larger boot disks).

## Generation 1 vs Generation 2

| Feature | Gen 1 | Gen 2 |
|---------|-------|-------|
| Firmware | BIOS | UEFI |
| Boot disk | IDE | SCSI |
| Boot from VHDX > 2 TB | No | Yes |
| Secure Boot | No | Yes |
| PXE from synthetic NIC | No | Yes |
| Supported guests | Most | Win 8 / Srv 2012+ x64, modern Linux |

**Use Gen 2** for everything that supports it.

## 1. Create a VM via PowerShell

```powershell
$VMName   = "dc01"
$VMRoot   = "D:\VMs"
$Switch   = "vSwitch-Internal"
$IsoPath  = "D:\VMs\ISOs\WindowsServer2022.iso"

New-VM -Name $VMName `
       -Generation 2 `
       -MemoryStartupBytes 4GB `
       -Path $VMRoot `
       -NewVHDPath "$VMRoot\$VMName\$VMName.vhdx" `
       -NewVHDSizeBytes 80GB `
       -SwitchName $Switch

# CPU
Set-VMProcessor -VMName $VMName `
                -Count 4 `
                -ExposeVirtualizationExtensions $true   # for nested

# Memory - dynamic with caps
Set-VMMemory -VMName $VMName `
             -DynamicMemoryEnabled $true `
             -MinimumBytes 2GB `
             -StartupBytes 4GB `
             -MaximumBytes 8GB `
             -Buffer 20

# DVD with install ISO
Add-VMDvdDrive -VMName $VMName -Path $IsoPath

# Boot order: DVD first for install, then HDD
$dvd = Get-VMDvdDrive -VMName $VMName
$hdd = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -BootOrder $dvd, $hdd

# Integration services - enable all
Get-VMIntegrationService -VMName $VMName | Enable-VMIntegrationService

# Automatic actions
Set-VM -Name $VMName `
       -AutomaticStartAction StartIfRunning `
       -AutomaticStartDelay 30 `
       -AutomaticStopAction Save `
       -CheckpointType Production    # crash-consistent, app-aware

Start-VM -Name $VMName
```

Or use the bundled script:

```powershell
.\scripts\New-LabVM.ps1 -VMName dc01 `
                        -CPU 4 -MemoryGB 4 -DiskGB 80 `
                        -SwitchName vSwitch-Internal `
                        -IsoPath D:\VMs\ISOs\WindowsServer2022.iso
```

## 2. Linux Guest Specifics

For Ubuntu/Debian/Rocky Gen 2 VMs:

```powershell
# Disable Secure Boot for distros without Microsoft UEFI CA signed loader
Set-VMFirmware -VMName ubuntu-01 -EnableSecureBoot Off

# Or use Microsoft UEFI CA template (works with signed shim/grub on Ubuntu)
Set-VMFirmware -VMName ubuntu-01 -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
```

Inside the guest, install Hyper-V integration tools:

```bash
# Modern kernels already include hv_* drivers - just install user-space tools
sudo apt install -y linux-tools-virtual linux-cloud-tools-virtual hyperv-daemons
sudo systemctl enable --now hv-kvp-daemon hv-vss-daemon hv-fcopy-daemon
```

## 3. VM Hardening Checklist

```powershell
# Disable time sync if the VM runs its own NTP (DCs especially)
Disable-VMIntegrationService -VMName dc01 -Name "Time Synchronization"

# Set production checkpoints (default in Srv 2016+)
Set-VM -Name dc01 -CheckpointType Production

# Enable Shielded VM features (TPM, encrypted state) - optional
Set-VMSecurity -VMName dc01 `
               -EncryptStateAndVmMigrationTraffic $true `
               -VirtualizationBasedSecurityOptOut $false
Set-VMKeyProtector -VMName dc01 -NewLocalKeyProtector
Enable-VMTPM -VMName dc01
```

## 4. Resource Metering

Track CPU/RAM/disk/network per VM for chargeback or sizing analysis:

```powershell
Enable-VMResourceMetering -VMName dc01
# ... let it run for a while ...
Measure-VM -VMName dc01 | Format-List
Reset-VMResourceMetering -VMName dc01
```

## 5. Connect to the Console

```powershell
# Enhanced Session Mode (recommended for Windows guests)
vmconnect.exe localhost dc01

# Or from PowerShell remoting once OS is installed
Enter-PSSession -VMName dc01 -Credential (Get-Credential)
```

## 6. Convert to Template

1. Generalize the guest: `C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown` (Windows) or `cloud-init clean` (Linux).
2. Export the VM as the gold image:

```powershell
Export-VM -Name dc01-template -Path "D:\VMs\Exports\Templates"
```

3. Future VMs are created via `Import-VM -Path ... -Copy -GenerateNewId` + rename + sysprep mini-setup answer file.

## 7. Delete / Reset

```powershell
# Clean delete - removes config but NOT vhdx files (safety)
Stop-VM   -Name test-vm -TurnOff -Force
Remove-VM -Name test-vm -Force

# Manually clean disks
Remove-Item "D:\VMs\test-vm" -Recurse -Force
```
