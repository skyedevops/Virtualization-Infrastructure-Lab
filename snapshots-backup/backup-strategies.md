# Backup Strategies

The lab follows the **3-2-1 rule**:

- **3** copies of every important dataset
- **2** different media (local SSD/HDD + cloud)
- **1** copy off-site

Backups are independent of snapshots and live on a separate datastore.

## Tier-Based Schedule

| Tier | Targets | Frequency | Retention | Method |
|------|---------|-----------|-----------|--------|
| 0 - Critical | dc01, fs01, pfSense config | every 6 h | 7 daily, 4 weekly, 6 monthly | `vzdump` / `Export-VM` + rclone to B2 |
| 1 - Important | App / DMZ VMs | nightly | 7 daily, 4 weekly | `vzdump` to NAS + weekly B2 |
| 2 - Convenience | Test / dev VMs | weekly | 4 weekly | `vzdump` to NAS |
| 3 - Disposable | Linked clones | none | rebuild from golden | n/a |

## Proxmox VE - `vzdump` + Proxmox Backup Server (PBS)

PBS provides deduplicated, encrypted, incremental-forever backups - the gold standard for Proxmox.

### Add PBS as a storage on each PVE node

```bash
pvesm add pbs pbs01 \
  --server 10.10.99.10 \
  --datastore lab-store \
  --username root@pam \
  --password '<token>' \
  --fingerprint '<sha256>'
```text

### Datacenter > Backup job (UI) or `/etc/pve/jobs.cfg`

```conf
vzdump: lab-nightly
        schedule mon..sun 02:00
        all 1
        storage pbs01
        mode snapshot
        compress zstd
        prune-backups keep-last=3,keep-daily=7,keep-weekly=4,keep-monthly=6
        mailnotification failure
        mailto root
```text

Or run ad hoc:

```bash
bash /workspaces/Virtualization-Infrastructure-Lab/hypervisors/proxmox-ve/scripts/backup-all-vms.sh
```text

## Hyper-V - Export + Windows Server Backup

### Daily checkpoint + weekly full export

```powershell
Register-ScheduledJob -Name "Backup-Lab-VMs" `
  -ScriptBlock {
      & "C:\Scripts\Backup-VMCheckpoints.ps1" -ExportPath "E:\Exports" -RetainDays 7
  } `
  -Trigger (New-JobTrigger -Daily -At "02:30")
```text

### Application-aware (Windows Server Backup)

```powershell
Install-WindowsFeature -Name Windows-Server-Backup

$policy = New-WBPolicy
$volumes = Get-WBVolume -AllVolumes | Where-Object MountPath -NE 'D:\'
Add-WBVolume          -Policy $policy -Volume $volumes
Add-WBSystemState     -Policy $policy
Add-WBBareMetalRecovery -Policy $policy
$target = New-WBBackupTarget -NetworkPath "\\nas.lab.local\backup\hyperv01"
Add-WBBackupTarget   -Policy $policy -Target $target
Set-WBSchedule       -Policy $policy -Schedule "01:00"
Set-WBPolicy         -Policy $policy
```text

## VMware Workstation - File-Level + Optional Veeam Agent

Workstation has no built-in backup, so use either:

1. **VM-level** - power off the VM (or snapshot + clone) and copy `D:\VMs\<name>` to the NAS.
2. **In-guest** - install [Veeam Agent Free](https://www.veeam.com/windows-endpoint-server-backup-free.html) (Windows) or `restic` (Linux) inside the guest.

PowerShell helper for copy:

```powershell
$Source = "D:\VMs"
$Dest   = "\\nas.lab.local\backup\workstation"
$Today  = (Get-Date -f yyyyMMdd)
robocopy $Source "$Dest\$Today" /MIR /MT:16 /R:1 /W:5 /LOG:"$env:TEMP\vmware-backup-$Today.log"
```text

## VirtualBox - Export to OVA

```bash
DATE=$(date +%Y%m%d)
DEST="/mnt/backup/vbox/$DATE"
mkdir -p "$DEST"
for VM in $(VBoxManage list vms | awk -F\" '{print $2}'); do
    VBoxManage controlvm "$VM" savestate 2>/dev/null || true
    VBoxManage export "$VM" -o "$DEST/${VM}.ova" --manifest
done
```text

## In-Guest Linux - restic

```bash
sudo apt install -y restic
sudo restic init -r b2:lab-bucket:/restic
sudo restic backup -r b2:lab-bucket:/restic /etc /home /var/log /var/lib/postgresql \
  --exclude /var/lib/postgresql/*/*/log
sudo restic -r b2:lab-bucket:/restic forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```text

Run via systemd timer (`restic-backup.timer`, `OnCalendar=*-*-* 03:30:00`).

## In-Guest Windows - wbadmin / Veeam Agent Free

```powershell
# wbadmin to a NAS share
wbadmin start backup `
  -backupTarget:\\nas.lab.local\backup\$env:COMPUTERNAME `
  -include:C: `
  -allCritical -quiet
```text

## Off-site (Cloud)

`rclone` to Backblaze B2:

```bash
# One-time config on the backup server / NAS
rclone config         # add remote "b2lab" of type backblaze

# Nightly script
rclone sync /mnt/backup/proxmox b2lab:lab-bucket/proxmox \
  --backup-dir b2lab:lab-bucket/proxmox-history/$(date +%Y%m%d) \
  --transfers 4 --bwlimit 5M --b2-hard-delete \
  --log-file /var/log/rclone-offsite.log -v
```text

Lifecycle on B2: rules to roll backups older than 90 days into Glacier, hard-delete after 1 year.

## Encryption

- PBS supports client-side AES-256 + GCM. Enable when adding the datastore.
- `restic` encrypts everything client-side with a passphrase. **Store the passphrase off-machine** (password manager + paper copy in a safe).
- B2 supports server-side encryption with B2-managed keys; combine with client-side for defense-in-depth.

## Cost Awareness

| Service | Notional cost (2026) |
|---------|----------------------|
| Backblaze B2 storage | ~$0.006 / GB / month |
| Backblaze B2 egress to AWS / Cloudflare | free with B2 Bandwidth Alliance |
| AWS S3 Standard | ~$0.023 / GB / month |
| AWS S3 Glacier Deep Archive | ~$0.00099 / GB / month |

A 500 GB lab backup off-site to B2 = ~$3/month. Restore once-a-year would cost a few dollars in download.
