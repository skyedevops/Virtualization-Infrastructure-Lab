# Hyper-V - Installation

## 1. Host Verification

Run on the target host as Administrator:

```powershell
# Hardware support
Get-ComputerInfo -Property "HyperV*"

# Expected:
# HyperVRequirementDataExecutionPreventionAvailable : True
# HyperVRequirementSecondLevelAddressTranslation    : True
# HyperVRequirementVirtualizationFirmwareEnabled    : True
# HyperVRequirementVMMonitorModeExtensions          : True
```text

If any field is `False`, fix the BIOS/UEFI setting before continuing.

## 2. Install the Hyper-V Role

### Windows Server 2019 / 2022

```powershell
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
```text

### Windows 10 / 11 Pro or Enterprise

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
Restart-Computer
```text

Reboot is mandatory.

## 3. Post-Install Configuration

Run the bundled helper script:

```powershell
.\scripts\Enable-HyperVRole.ps1 -VMRoot "D:\VMs" -VHDRoot "D:\VMs\VHD"
```text

The script:

1. Sets default VM and VHD paths to a dedicated data drive
2. Enables Enhanced Session Mode
3. Configures Live Migration (single-host disabled, multi-host enabled with CredSSP/Kerberos)
4. Enables NUMA spanning
5. Creates the three baseline vSwitches via `New-VMSwitch-Lab.ps1`

## 4. Network Switches

```powershell
# External - bridged to physical NIC, management OS shares it
New-VMSwitch -Name "vSwitch-External" `
             -NetAdapterName "Ethernet" `
             -AllowManagementOS $true `
             -Notes "Lab External - LAN uplink"

# Internal - host can reach VMs, no physical NIC
New-VMSwitch -Name "vSwitch-Internal" `
             -SwitchType Internal `
             -Notes "Lab Internal - 10.10.20.0/24"

# Private - isolated, VM-to-VM only
New-VMSwitch -Name "vSwitch-Private" `
             -SwitchType Private `
             -Notes "Lab Private - isolated test bench"
```text

## 5. Storage Layout

Recommended:

```text
D:\VMs\
  Virtual Machines\        <- .vmcx config files
  Virtual Hard Disks\      <- .vhdx
  Snapshots\               <- .avhdx checkpoint chains
  Exports\                 <- backup target
  ISOs\                    <- install media
```text

Apply via:

```powershell
Set-VMHost -VirtualMachinePath "D:\VMs\Virtual Machines" `
           -VirtualHardDiskPath "D:\VMs\Virtual Hard Disks"
```text

## 6. Validation

```powershell
Get-VMHost | Format-List Name, *Path*, MaximumVirtualMachineMemoryBytes
Get-VMSwitch | Format-Table Name, SwitchType, NetAdapterInterfaceDescription
```text

## 7. Remote Management (Optional)

Allow Hyper-V Manager from an admin workstation:

```powershell
# On the Hyper-V host
Enable-PSRemoting -Force
Enable-WSManCredSSP -Role Server -Force
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "admin-pc" -Force

# On the admin workstation (must be same AD domain or use CredSSP)
Enable-WSManCredSSP -Role Client -DelegateComputer "hyperv-host01.lab.local" -Force
```text

Then open Hyper-V Manager -> Connect to Server -> `hyperv-host01.lab.local`.
