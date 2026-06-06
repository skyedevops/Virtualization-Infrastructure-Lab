# VMware Workstation - Installation

## 1. Host Prerequisites

| Item | Requirement |
|------|-------------|
| OS | Windows 10/11 64-bit or Linux 64-bit (kernel 5.x+) |
| CPU | x86-64 with VT-x or AMD-V |
| RAM | 8 GB minimum, 16+ GB recommended |
| Disk | 1.5 GB for application, plus VM storage |
| Hyper-V | **Must be disabled** on Windows hosts before install (or use Workstation 16+ with WHP backend) |

### Disable Hyper-V on Windows (if needed)

```powershell
# Run as Administrator
bcdedit /set hypervisorlaunchtype off
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
Restart-Computer
```text

For Workstation 16+ using the Windows Hypervisor Platform (WHP) backend, Hyper-V can remain enabled.

## 2. Download & Install

1. Download the latest Workstation Pro from <https://www.vmware.com/products/workstation-pro.html>.
2. Run the installer with these options:
   - Enhanced Keyboard Driver: **Yes** (recommended for Linux guests)
   - Add to PATH: **Yes** (enables `vmrun` from any shell)
   - Check for updates: **Yes**
   - Join CEIP: optional
3. Enter the license key (or use the free Player tier for non-commercial use).

## 3. First-Run Configuration

After launch:

- **Edit -> Preferences -> Workspace**
  - Default VM location: `D:\VMs` (separate disk from OS)
  - Default for hardware compatibility: `Workstation 17.x`
- **Edit -> Preferences -> Memory**
  - Reserved RAM: leave OS at least 4 GB headroom
  - "Fit all virtual machine memory into reserved host RAM"
- **Edit -> Preferences -> Priority**
  - Process priority: `Normal` for both running/idle
- **Edit -> Virtual Network Editor** (Run as Admin)
  - Validate VMnet0 (bridged), VMnet1 (host-only), VMnet8 (NAT) all exist
  - See [networking.md](networking.md) for custom networks

## 4. Verify Install

```powershell
vmware -v
vmrun list
```text

Expected output:

```text
VMware Workstation 17.5.x build-xxxxxxxx
Total running VMs: 0
```text

## 5. Recommended Post-Install Tasks

- Install the VMware OVF Tool: <https://developer.vmware.com/web/tool/ovf>
- Create an ISO library folder (e.g., `D:\ISOs\`) and stage Ubuntu, Rocky, Win Srv 2022 ISOs
- Create a snapshot baseline of the host immediately after install (system image or Acronis)
