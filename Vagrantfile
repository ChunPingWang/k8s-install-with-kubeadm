# -*- mode: ruby -*-
# vi: set ft=ruby :

# Kubernetes minor version (controls which apt repo is used)
K8S_VERSION = "1.32"

# Ubuntu 24.04 LTS Vagrant box
BOX_NAME = "bento/ubuntu-24.04"

NODES = [
  { name: "k8s-master",  ip: "192.168.56.10", memory: 4096, cpus: 2, role: "master" },
  { name: "k8s-worker1", ip: "192.168.56.11", memory: 2048, cpus: 2, role: "worker" },
  { name: "k8s-worker2", ip: "192.168.56.12", memory: 2048, cpus: 2, role: "worker" },
]

Vagrant.configure("2") do |config|
  config.vm.box = BOX_NAME

  # 清除上次的 join-command 以避免舊 token 被使用
  config.trigger.before :up do |trigger|
    trigger.run = { inline: "rm -f #{File.dirname(__FILE__)}/join-command.sh" }
  end

  NODES.each do |node|
    config.vm.define node[:name] do |vm_config|
      vm_config.vm.hostname = node[:name]

      # Host-only 私有網路（VirtualBox 預設允許 192.168.56.0/21）
      vm_config.vm.network "private_network", ip: node[:ip]

      vm_config.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.memory = node[:memory]
        vb.cpus   = node[:cpus]
        # 讓 VM 使用 host 的 DNS，避免解析問題
        vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
        vb.customize ["modifyvm", :id, "--natdnsproxy1",        "on"]
      end

      # 所有節點共用的初始化腳本
      vm_config.vm.provision "shell",
        path:    "scripts/common.sh",
        env:     { "NODE_IP" => node[:ip], "K8S_VERSION" => K8S_VERSION }

      # 依角色執行不同的後續腳本
      if node[:role] == "master"
        vm_config.vm.provision "shell",
          path:    "scripts/master.sh",
          env:     { "MASTER_IP" => node[:ip] }
      else
        vm_config.vm.provision "shell",
          path: "scripts/worker.sh"
      end
    end
  end
end
