
# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Monitoring lab: 1 monitor VM (OTel Collector + Prometheus + Grafana) and
# 2 app VMs (orders, inventory). Run from Windows PowerShell: `vagrant up`.

# ---------------------------------------------------------------------------
# Edit VM sizing / addressing here.
# ---------------------------------------------------------------------------
BOX = "ubuntu/jammy64"
# Seconds to wait for SSH on boot. VirtualBox on top of Hyper-V (WSL2 enabled) can take
# several minutes to boot a VM; 300 (Vagrant default) is enough on a non-Hyper-V host.
BOOT_TIMEOUT = 900

# Project folders copied to /vagrant inside every VM on each provision.
SYNC_DIRS = %w[provision services exporters monitoring scripts]

VMS = {
  "monitor" => { ip: "192.168.56.10", cpus: 2, memory: 3072, role: "monitor" },  # 3 GB: Tempo (phase 2)
  "app1"    => { ip: "192.168.56.11", cpus: 1, memory: 1024, role: "app1" },
  "app2"    => { ip: "192.168.56.12", cpus: 1, memory: 1024, role: "app2" },
}
# ---------------------------------------------------------------------------

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  config.vm.box_check_update = false
  config.vm.boot_timeout = BOOT_TIMEOUT

  # The ubuntu/jammy64 box has no vboxsf support, so instead of a shared folder the
  # project files are uploaded over SSH and copied to /vagrant on every provision
  # (`vagrant provision <vm>` re-syncs them).
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.provision "clean-upload", type: "shell", inline: "rm -rf /tmp/monlab && mkdir -p /tmp/monlab && chown vagrant: /tmp/monlab"
  SYNC_DIRS.each do |dir|
    config.vm.provision "upload-#{dir}", type: "file", source: dir, destination: "/tmp/monlab/#{dir}"
  end
  config.vm.provision "sync", type: "shell",
    inline: "rm -rf /vagrant && cp -r /tmp/monlab /vagrant && find /vagrant -type f -exec sed -i 's/\\r$//' {} +"

  VMS.each do |name, opts|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: opts[:ip]

      node.vm.provider "virtualbox" do |vb|
        vb.name   = "monlab-#{name}"
        vb.cpus   = opts[:cpus]
        vb.memory = opts[:memory]
        # The Ubuntu box writes a serial console log into the project folder; disable it.
        vb.customize ["modifyvm", :id, "--uartmode1", "disconnected"]
      end

      node.vm.provision "common", type: "shell", path: "provision/common.sh"
      if opts[:role] != "monitor"
        node.vm.provision "exporters", type: "shell", path: "provision/exporters.sh"
      end
      node.vm.provision opts[:role], type: "shell", path: "provision/#{opts[:role]}.sh"
    end
  end
end
