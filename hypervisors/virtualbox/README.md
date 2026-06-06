# Oracle VirtualBox

VirtualBox is an open-source, cross-platform Type-2 hypervisor. In this lab it serves as the:

- Portable lab for Linux/macOS hosts (no Hyper-V conflict on Windows)
- Vagrant backend for reproducible developer VMs
- Quick-and-dirty hypervisor for one-off testing on any laptop

## Version Tested

| Component | Version |
|-----------|---------|
| VirtualBox | 7.0.x |
| Extension Pack | 7.0.x (PUEL license for personal/eval use) |
| Guest Additions | Bundled with VBox version |

## Contents

- [installation.md](installation.md) - Install + Extension Pack
- [vm-configuration.md](vm-configuration.md) - GUI + `VBoxManage` CLI

## Quick CLI - `VBoxManage`

```bash
# Inventory
VBoxManage list vms
VBoxManage list runningvms
VBoxManage list hostonlyifs
VBoxManage list natnetworks
VBoxManage showvminfo "ubuntu-01" --machinereadable | head

# Power
VBoxManage startvm  "ubuntu-01" --type headless
VBoxManage controlvm "ubuntu-01" acpipowerbutton
VBoxManage controlvm "ubuntu-01" poweroff
VBoxManage controlvm "ubuntu-01" pause
VBoxManage controlvm "ubuntu-01" resume

# Snapshots
VBoxManage snapshot "ubuntu-01" take      "pre-update" --description "Before kernel"
VBoxManage snapshot "ubuntu-01" list
VBoxManage snapshot "ubuntu-01" restore   "pre-update"
VBoxManage snapshot "ubuntu-01" delete    "pre-update"

# Clone
VBoxManage clonevm "golden-ubuntu" --name "test-01" --register \
  --options link --snapshot "golden"
```text

## When to Use VirtualBox

- You're on a host where you cannot install/enable Hyper-V (macOS, older laptops, dev workstations).
- You want the simplest possible "double-click an ova" workflow.
- You're integrating with **Vagrant** for IaC-driven local development.

## Vagrant Integration

VirtualBox is Vagrant's default provider. A minimal Vagrantfile that brings up an Ubuntu box:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "dev01"
  config.vm.network "private_network", ip: "192.168.56.50"
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "dev01"
    vb.cpus   = 2
    vb.memory = 2048
    vb.customize ["modifyvm", :id, "--graphicscontroller", "vmsvga"]
  end
  config.vm.provision "shell", inline: "apt-get update && apt-get install -y nginx"
end
```text

```bash
vagrant up
vagrant ssh
vagrant halt
vagrant destroy -f
```text
