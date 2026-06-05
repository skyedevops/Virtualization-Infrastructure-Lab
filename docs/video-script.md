# Video Script: Building a Virtualization & Infrastructure Lab

> Format: long-form technical YouTube video (15-20 min target)
> Audience: sysadmins, cloud/DevOps engineers, students
> Tone: candid, opinionated, evidence-driven
> Repo referenced: <https://github.com/skyedevops/Virtualization-Infrastructure-Lab>

---

## PRE-ROLL (0:00 - 0:45)

**\[TITLE CARD - 2 seconds\]**
"Building a Virtualization & Infrastructure Lab from Scratch"

**\[B-ROLL\]** Spinning hard drives, a server rack, terminal scrolling.

**\[SPEAKER\]**

> "I run four hypervisors, eleven VLANs, and a 3-2-1 backup pipeline on
> hardware I bought second-hand. This is the build process, the design
> trade-offs, and the half-dozen things I'd do differently if I started
> over. Repo link is in the description."

**\[ON-SCREEN\]** GitHub URL with star/fork badges.

---

## SEGMENT 1 - What Is This Lab For? (0:45 - 2:00)

**\[B-ROLL\]** Show the repo's README.md, scroll through the directory tree.

**\[SPEAKER\]**

> "Before I bought any hardware I wrote down three goals. Number one -
> hands-on time with the four hypervisors I'd actually see in a job:
> VMware Workstation, Hyper-V, Proxmox, and VirtualBox. Number two -
> learn the operations side: snapshots, backups, restores, networking,
> capacity planning. And number three - prove I can rebuild the whole
> thing from scratch using a single repo of docs and scripts. Not a
> click-by-click YouTube tutorial. A real engineering artifact."

**\[ON-SCREEN GRAPHIC\]** Three columns: "Learn the tool" / "Run it like prod" / "Make it reproducible"

> "If those goals sound like your job description, this lab is worth
> your evening."

**\[SPEAKER\]**

> "Trade-off I made: I didn't build an ESXi cluster. vSphere is the
> 800-pound gorilla in enterprise, but the free tier kills vCenter and
> vMotion, which is the interesting part. Proxmox gives me 90% of the
> same operational patterns for free and is a much better learning
> vehicle."

---

## SEGMENT 2 - Hardware & Cost (2:00 - 3:30)

**\[B-ROLL\]** Shots of the actual host hardware - tower, mini-PC, NAS.

**\[SPEAKER\]**

> "Total cost, used market: about 1,200 US dollars. That's a Ryzen 7
> workstation, a Mini-ITX Proxmox box, a four-bay NAS, and a managed
> switch. I did NOT buy enterprise gear, and you shouldn't either for a
> home lab. The point is to learn the *abstractions*; the CPUs don't
> matter as long as VT-x and IOMMU are exposed."

**\[ON-SCREEN GRAPHIC\]** Hardware table from `docs/hardware-requirements.md`.

> "Two non-obvious requirements. First, every host CPU needs
> virtualization extensions - `vmx` on Intel, `svm` on AMD. If you don't
> see those flags in `/proc/cpuinfo`, the BIOS setting is wrong, not
> the hardware. Second, the Proxmox node needs at least 32 GB of RAM if
> you want to run more than four VMs. RAM is the bottleneck 90% of the
> time, not cores and not disk."

---

## SEGMENT 3 - Hypervisor Selection (3:30 - 6:30)

**\[B-ROLL\]** Quad split-screen showing each hypervisor's web UI / GUI.

**\[SPEAKER\]**

> "Why four hypervisors? Because the operational model is different in
> each, and the only way to feel those differences is to use all four
> on the same workload. Let me walk through the choice and the
> trade-off per slot."

**\[ON-SCREEN\]** Table from the repo's README.

### VMware Workstation (3:50)

> "Workstation lives on my workstation. Use case: nested labs and
> portable demos. A single `.vmx` file I can hand to a colleague and
> they can boot my exact lab on their laptop. Trade-off: it's the only
> Type-2 hypervisor that doesn't make me feel like I'm in a 2008
> tutorial. Also, `vmrun` is the only one with a clean CLI for
> snapshots. The killer feature nobody talks about: linked clones boot
> in seconds because they only store deltas. I use this constantly."

### Hyper-V (4:30)

> "Hyper-V is the Windows Server hypervisor. The reason it's in the
> lab is that most production Windows environments use it, and the
> management story is fundamentally different from Proxmox or ESXi.
> PowerShell-native, no web UI, role-based. PowerShell also gives you
> a single API to do everything - checkpoints, exports, switch
> config, integration services. The trade-off is that the Hyper-V
> Manager GUI is awful and the historical 'Generation 1' VMs are
> trapped on IDE boot disks. Always build Gen 2."

### Proxmox VE (5:20)

> "Proxmox is the open-source centerpiece. Web UI on port 8006, REST
> API on the same port, KVM and LXC on the same node, real clustering
> with Corosync, and a first-party backup server that does
> deduplication and encryption. The trade-off: the web UI is built for
> Linux engineers, not Windows admins. If you have a strong
> Linux/KVM background you'll love it. If you've only ever clicked
> vCenter, expect a two-week learning curve."

### VirtualBox (6:00)

> "VirtualBox is the 800-pound Gorilla's little brother. I run it on
> the laptop for quick OS testing, and as the Vagrant provider when
> I'm spinning up reproducible dev environments. The trade-off is that
> it's the slowest of the four and you can't over-commit memory.
> Treat it as a dev tool, not a datacenter hypervisor."

> "Quick decision matrix: production-grade server - Hyper-V or Proxmox.
> Desktop/portable - VMware Workstation. Linux-vendor integration -
> Proxmox. Cross-platform Vagrant - VirtualBox."

---

## SEGMENT 4 - Network Design (6:30 - 9:00)

**\[B-ROLL\]** Topology diagram from `docs/lab-topology.md`, animated.

**\[SPEAKER\]**

> "The network is where most home labs fail. Everyone buys the
> hardware, then connects everything to the default flat subnet and
> wonders why their DHCP is dropping. Five VLANs from day one.
> Non-negotiable."

**\[ON-SCREEN\]** VLAN table from `networking/README.md`.

> "MGMT for hypervisors and IPMI. SERVERS for AD, DNS, file, app.
> CLIENTS for the Win10/11 fleet. DMZ for anything with a port
> forwarded inbound. STORAGE for NAS, backup targets, no internet
> egress. The reason I keep them separate is so that when a test VM
> gets popped - and it will - the blast radius is one VLAN."

### pfSense (7:20)

> "Routing and firewalling is done by pfSense running as a VM on
> Proxmox. The trade-off versus running it bare-metal is that pfSense
> depends on the Proxmox node. The advantage is that I get
> centralized logs, snapshots of the firewall itself, and I can move
> the VM to another node in 30 seconds."

**\[ON-SCREEN GRAPHIC\]** Trunk port diagram - one NIC, multiple VLAN tags, sub-interfaces in pfSense.

> "Single NIC, VLAN trunk, sub-interfaces in pfSense. If you give
> every VLAN its own physical NIC you hit the consumer NIC ceiling at
> four. Trunks and 802.1Q sub-interfaces scale to the thousands."

### Virtual switches per hypervisor (8:20)

> "Each hypervisor presents the same five VLANs differently.
> Hyper-V needs explicit `Set-VMNetworkAdapterVlan` per NIC. Proxmox
> is the most elegant: `bridge-vlan-aware yes` on `vmbr0`, then per-VM
> `tag=20`. VMware Workstation is the worst: you tag inside the guest
> OS, not at the vSwitch. The repo's `networking/virtual-switches.md`
> has the per-platform commands if you need a quick reference."

---

## SEGMENT 5 - Storage Design (9:00 - 10:30)

**\[B-ROLL\]** NVMe drive being installed, ZFS pool creation terminal.

**\[SPEAKER\]**

> "Three tiers. NVMe for active VM disks. SATA SSD for ISO library and
> secondary VM disks. NAS for backups and archive. The reason NVMe
> matters more than SATA SSD for VM disks is random IOPS - you
> quickly hit a saturation wall on a SATA SSD when 10 VMs boot at
> once. NVMe is overkill for sequential throughput but essential for
> fork-bomb boot storms."

### File system choice (9:40)

> "Proxmox root filesystem: ZFS. Why. Built-in snapshots that survive
> reboots. Send/receive for off-site replication. Self-healing with
> scrubs. Native compression. The trade-off is RAM - ZFS ARC eats
> everything you don't cap, and if you don't set `zfs_arc_max` you'll
> wonder why the OOM killer is paging out your VMs. I cap at 25% of
> host RAM."

### Disk provisioning (10:10)

> "Thin / dynamic disks by default. Pre-allocate only for databases.
> The reason: thin provisioning lets you over-commit the datastore. A
> 1 TB datastore will happily hold 5 TB of allocated-but-mostly-empty
> disks. The day you actually fill 5 TB, you'll have migrated to
> bigger storage anyway."

---

## SEGMENT 6 - Backup Strategy (10:30 - 12:30)

**\[B-ROLL\]** `vzdump` running, `rclone` pushing to B2, recovery drill demo.

**\[SPEAKER\]**

> "Snapshots are not backups. I say that three times a week at
> minimum to anyone who will listen. A snapshot stored on the same
> datastore as the VM dies when that datastore dies. Backups are
> off-machine. Period."

### 3-2-1 (11:00)

> "3-2-1 means: three copies of the data, on two different media,
> one off-site. In the lab: production on the hypervisor's local NVMe
> (copy 1), nightly backup to the NAS (copy 2, different media), and
> weekly push to Backblaze B2 via rclone (copy 3, off-site, third
> medium). About three dollars a month for 500 GB. The whole point
> of off-site is to survive the scenarios your snapshots can't:
> ransomware, fire, theft, the dog chewing the wrong cable."

### Application-consistent vs crash-consistent (11:45)

> "Proxmox's `vzdump` defaults to snapshot mode, which is
> crash-consistent at the filesystem level. For a domain controller
> that's a problem. The fix is the QEMU guest agent, which Proxmox
> uses to quiesce the filesystem - or for Windows guests, VSS - so
> the resulting backup is as if you'd cleanly shut the VM down.
> Always install the guest agent. Always."

### Why I picked PBS (12:15)

> "Proxmox Backup Server. Why not just rsync to B2? Deduplication. PBS
> fingerprints every 4 KB block, deduplicates across all VMs, and
> the resulting backups are 5-10x smaller than rsync. The trade-off
> is operational complexity: another VM to maintain, another
> encryption key to manage. Worth it for me at >3 VMs."

---

## SEGMENT 7 - Golden Images and Templates (12:30 - 14:00)

**\[B-ROLL\]** Sysprep running, `qm snapshot golden`, linked clone spinning up.

**\[SPEAKER\]**

> "The number-one time saver in any lab is a golden image. Build the
> perfect Ubuntu VM once, sysprep/generalize, snapshot it, and every
> future test VM is a linked clone in five seconds and 200 MB of
> delta."

### Linux (12:50)

> "Linux generalizing is: clear `machine-id`, remove SSH host keys,
> clear cloud-init state, zero out bash history, then shut down.
> Power off, snapshot as `golden`. Done. Proxmox makes this a 5-line
> script - it's in the repo as `create-vm-from-cloudimg.sh`."

### Windows (13:20)

> "Windows generalizing is `sysprep /generalize /oobe /shutdown`. The
> catch: sysprep has a 3-sid-reset limit before Windows refuses to
> re-arm. So your golden image can't be cloned 4 times in a row
> without re-running sysprep. The pro workaround is to re-capture
> the golden from a fresh sysprep after every N clones. Most people
> never hit the limit; don't worry about it until you do."

### Why I avoided Packer / cloud-init-only builds (13:50)

> "Packer is the right answer for production. For a home lab, the
> 30 minutes I'd spend building the Packer config plus the 200 MB
> Packer image is not worth it. Manual + scripts hits the right
> trade-off: reproducible enough that I can rebuild in an afternoon,
> fast enough that I don't get blocked on infrastructure to do
> infrastructure."

---

## SEGMENT 8 - Automation Choices (14:00 - 16:00)

**\[B-ROLL\]** Script executions, cron jobs, scheduled tasks.

**\[SPEAKER\]**

> "I automated the repetitive 20% and left the rest to the GUI. The
> four scripts worth your time are: snapshot rotation, backup with
> retention, health check, and cross-hypervisor inventory. The repo
> has all of them."

### Snapshot rotation (14:20)

> "Daily at 3 AM, take a snapshot of every VM and container. Prune
> anything with the `auto-daily-` prefix older than 7 days. Weekly
> on Sunday, take an extra `auto-weekly-` snapshot pruned at 4 weeks.
> Anything that survives a week of use is probably important; anything
> that doesn't, isn't."

### Backup with retention (14:50)

> "Once you have retention on snapshots, the backups are
> straightforward: `vzdump` with `keep-last=3,keep-daily=7,keep-weekly=4`.
> The reason to keep the last 3 *unrelated* to dates is disaster
> recovery from a bad patch that took 3 days to detect."

### Health check (15:20)

> "Lab health is one bash script: uptime, load, RAM, disk, ZFS
> pools, cluster quorum, stale snapshots, failed PVE tasks. Exit
> code is the severity - 0 OK, 1 warn, 2 fail. Wire it to your
> monitoring system. Mine posts to a Discord webhook on fail."

### What I didn't automate (15:50)

> "VM provisioning. Yes, Terraform, Cloud-Init, and Ansible exist. No,
> I'm not using them on a 10-VM lab. The breakeven point for any
> config management tool is around VM number 30 or service number
> 100. Under that, you're paying the abstraction tax without getting
> the consistency dividend."

---

## SEGMENT 9 - What I'd Do Differently (16:00 - 18:00)

**\[B-ROLL\]** Side-by-side of v1 vs proposed v2 design.

**\[SPEAKER\]**

> "Six months in, here's what I'd change."

1. > "I would have bought one bigger host instead of two. The Windows
   > + Proxmox split made sense when I thought I'd run both heavily.
   > In practice, 80% of my time is on Proxmox. I would have bought
   > one server with 128 GB of RAM and called it done."

2. > "I would NOT have run pfSense as a VM initially. Running the
   > router on the same hardware as the VMs creates a chicken-and-egg
   > problem when the host dies. A 50-dollar fanless appliance for
   > pfSense is the right answer for a home lab."

3. > "I would have started with Proxmox Backup Server from day one. I
   > bolted it on month three, which meant I had three months of
   > unencrypted, un-deduplicated backups to migrate. Painful."

4. > "I would NOT have built out 11 VLANs on day one. Three would
   > have been enough. I added VLANs to solve problems I didn't have
   > yet. Resist the urge to over-architect."

5. > "I would have bought IPMI / BMC on every host. Power-cycling a
   > crashed Proxmox node by yanking the cable is not fun, and you
   > want console access without SSH when networking is broken."

6. > "I would have written a `make destroy` target from the start.
   > The ability to nuke the entire lab and rebuild it from a single
   > command is the difference between a lab you actually use and a
   > lab you're afraid to touch."

---

## SEGMENT 10 - Wrap-up (18:00 - 19:00)

**\[B-ROLL\]** Final tour of the running lab.

**\[SPEAKER\]**

> "If I had to summarize the design philosophy in one sentence: the
> lab should be the simplest thing that still teaches the real-world
> operation. Not a toy, not a copy-paste of enterprise hardware -
> just enough complexity to be honest about what production looks
> like."

> "The repo is in the description. It has every command, every
> script, every design decision from this build. Clone it, run the
> post-install scripts, and you'll have the same lab running on
> Saturday. Questions? Drop them in the comments. I read them all."

**\[ON-SCREEN\]** Subscribe button, related video cards, repo link.

**\[END CARD\]**

---

## BONUS SEGMENTS (optional, for YouTube chapters)

### B1 - Why no Kubernetes in the lab?

> "Three reasons. First, k8s has its own dedicated learning track
> that deserves its own repo. Second, the surface area of 'run k8s
> in a lab' is mostly the install path, not the operational
> patterns, and the install path is one well-documented tutorial
> away. Third, a 3-node k8s cluster on a 32 GB host will consume
> the entire lab, leaving no room to learn the rest. I do run k8s as
> a single-node k3s VM for app testing. That's enough."

### B2 - Why no vSphere / ESXi?

> "Two reasons. The free ESXi hypervisor is excellent, but you
> cannot manage more than one host with it - vCenter is the
> interesting management plane and it's licensed. Without vCenter
> you're running a single-host Type-1 hypervisor that's harder to
> install than Proxmox and less capable than vSphere. I picked
> Proxmox because it gives me the cluster + UI + API that vSphere
> would give me, without the license."

### B3 - Why no Nutanix / Red Hat Virtualization / XCP-ng?

> "XCP-ng is in the same category as Proxmox and a fine choice. I
> picked Proxmox over XCP-ng because the Proxmox community
> publishes more blog posts, more scripts, and the API is a normal
> REST API instead of XML-RPC over HTTPS. If you've got a XenServer
> background, XCP-ng is your faster on-ramp. Nutanix and RHV are
> enterprise products with enterprise pricing and enterprise
> complexity. Wrong tool for a home lab."

### B4 - Power and noise

> "Three things they don't tell you about a home lab. First, the
> electricity bill - my rack pulls 250 watts 24/7, about thirty
> dollars a month. Second, the noise - I moved the Proxmox box to a
> closet with a USB fan for ventilation. Third, the heat - one rack
> in a small room raises the ambient by two degrees. Plan for all
> three."

---

## PRODUCTION NOTES

- **Pacing**: roughly 1 minute per major topic; the "What I'd do
  differently" segment is intentionally slow to let viewers absorb.
- **B-roll**: capture the actual terminal output of the scripts in
  `hypervisors/proxmox-ve/scripts/` running against a live node.
- **Diagrams**: render the topology from `docs/lab-topology.md` in
  draw.io / Mermaid and animate the data path.
- **Timestamps in description**: list chapter markers at the start
  of each segment so viewers can jump to the trade-off section.
- **Pinned comment**: post the repo link + the four "what I'd
  change" items as a TL;DR for skim-watchers.
