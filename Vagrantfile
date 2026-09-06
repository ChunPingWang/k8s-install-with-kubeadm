# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# ═══════════════════════════════════════════════════════════════════════════
#  需求（Requirements）
# ═══════════════════════════════════════════════════════════════════════════
#  R1  一道 `vagrant up` 產出可用的 3 節點 Kubernetes 叢集（1 master + 2 worker）
#  R2  節點之間、以及 host → 節點，皆有穩定且可預測的 IP（不依賴 DHCP）
#  R3  可在 Windows / macOS / Linux host 上執行（作者主力環境為 Windows）
#  R4  版本可重現：同一份程式碼在不同時間執行應得到相同的元件版本
#  R5  可重複執行：`vagrant provision` 重跑不得破壞既有叢集
#
# ═══════════════════════════════════════════════════════════════════════════
#  設計決策（Design Decisions）
# ═══════════════════════════════════════════════════════════════════════════
#  D1  【共用 + 角色】腳本切成 common / master / worker 三支。
#      共用的節點前置作業（swap、核心模組、containerd、kubeadm 套件）佔了
#      九成篇幅且三種角色完全相同，抽出來可避免三份副本各自飄移。
#
#  D2  【參數用 env 傳遞，不用 args】provision 的 env: 讓腳本內是具名變數
#      （${NODE_IP}）而非位置參數（$1），新增參數時不會打亂既有順序。
#
#  D3  【private_network + 固定 IP】VirtualBox 的第一張網卡是 NAT，三台機器
#      上都是同一個 10.0.2.15，無法互相定址。因此額外掛一張 host-only 網卡，
#      叢集的所有通訊（apiserver、etcd、kubelet、Flannel VXLAN）都走它。
#      192.168.56.0/24 是 VirtualBox 預設允許的 host-only 網段，選它可以
#      避免使用者還要去改 /etc/vbox/networks.conf。
#
#  D4  【master 必須先開機】worker 的 join 指令由 master 產生。Vagrant 依
#      config.vm.define 的順序開機，因此 NODES 陣列中 master 必須排第一。
#
#  D5  【join 指令走 synced folder 傳遞】master 寫入 /vagrant/join-command.sh，
#      worker 輪詢等待。這是三台 VM 之間唯一的共享媒介，不需要額外的
#      key-value store，也不需要 host 端腳本介入。
#
#  D6  【trigger 用 Ruby block，不用 inline shell】← 這是踩過的坑
#      inline trigger 在 Windows host 上是交給 PowerShell 執行的
#      （vagrant/plugin/v2/trigger.rb: Platform.windows? → PowerShell.execute_inline）。
#      `rm -f <path>` 在 PowerShell 中會被解析成 `Remove-Item -f`，而 `-f`
#      同時符合 -Filter 與 -Force → 參數歧義錯誤 → exit code 1
#      → trigger 預設 on_error = :halt → **vagrant up 直接中止**。
#      trigger.ruby 由 Vagrant 自己的 Ruby runtime 執行，三大平台行為一致。
#
#  D7  【master 4G / worker 2G】control plane 要跑 etcd + apiserver +
#      scheduler + controller-manager，2G 會在 apiserver 啟動時 OOM。
#      worker 只跑 kubelet + kube-proxy + Flannel，2G 足夠且能讓
#      8G 記憶體的筆電還有餘裕。
#
#  D8  【每節點 2 vCPU】kubeadm 的 NumCPU preflight 要求 master ≥ 2。
#      給 worker 同樣的配置以保持節點同質性（scheduling 行為較好預測）。
#
# ═══════════════════════════════════════════════════════════════════════════
#  原則（Principles）
# ═══════════════════════════════════════════════════════════════════════════
#  P1  版本一律明確釘選（K8S_VERSION / BOX_NAME），不用 latest。
#      教學環境的價值在於「今天壞掉的原因和明天一樣」。
#  P2  拓樸資訊集中在檔案頂端的常數與 NODES 陣列，改叢集規模只改資料不改邏輯。
#  P3  host 端只做 Vagrant 做得到的事；任何需要 shell 的動作都放進 guest 腳本，
#      因為 guest 的 shell 環境（Ubuntu bash）是我們控制得了的，host 不是。
# ═══════════════════════════════════════════════════════════════════════════

# Kubernetes minor version (controls which apt repo is used)
K8S_VERSION = "1.32"

# Ubuntu 24.04 LTS Vagrant box
BOX_NAME = "bento/ubuntu-24.04"

# master.sh 會把 join 指令寫進 synced folder，對應到 host 端的這個檔案。
# 在 config 載入期就算好絕對路徑，trigger block 直接閉包捕捉，
# 不必在延遲執行時再解析 __FILE__。
JOIN_COMMAND_FILE = File.join(File.dirname(__FILE__), "join-command.sh")

# 節點拓樸：master 必須排第一（見 D4）
NODES = [
  { name: "k8s-master",  ip: "192.168.56.10", memory: 4096, cpus: 2, role: "master" },
  { name: "k8s-worker1", ip: "192.168.56.11", memory: 2048, cpus: 2, role: "worker" },
  { name: "k8s-worker2", ip: "192.168.56.12", memory: 2048, cpus: 2, role: "worker" },
]

Vagrant.configure("2") do |config|
  config.vm.box = BOX_NAME

  NODES.each do |node|
    config.vm.define node[:name] do |vm_config|
      # 只在 master 啟動前清除舊的 join-command（避免 worker 啟動時誤刪）。
      # 舊檔案裡的 token 只有 24 小時效期，若沿用會讓 worker 以
      # 「token expired」失敗，錯誤訊息又與真正的網路問題難以區分。
      if node[:role] == "master"
        vm_config.trigger.before :up do |trigger|
          trigger.name = "清除舊的 join-command.sh"
          # 跨平台實作，原因見檔頭 D6
          trigger.ruby do |_env, _machine|
            File.delete(JOIN_COMMAND_FILE) if File.exist?(JOIN_COMMAND_FILE)
          end
        end
      end
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
