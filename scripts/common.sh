#!/bin/bash
# 所有節點（master + worker）共用的初始化腳本（Ubuntu 24.04）
set -euo pipefail

NODE_IP="${NODE_IP}"
K8S_VERSION="${K8S_VERSION:-1.32}"

echo ">>> [common] 開始初始化節點 IP=${NODE_IP}, K8s=${K8S_VERSION}"

# ── 1. 停用 Swap ──────────────────────────────────────────────────────────────
echo ">>> [common] 停用 swap"
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# ── 2. 安裝基本工具 ───────────────────────────────────────────────────────────
echo ">>> [common] 安裝基本工具"
apt-get update -q
apt-get install -y -q \
  vim jq curl wget \
  iputils-ping net-tools \
  apt-transport-https ca-certificates gnupg \
  software-properties-common

# ── 3. 停用 UFW ───────────────────────────────────────────────────────────────
echo ">>> [common] 停用 UFW"
ufw disable || true

# ── 4. 載入核心模組 ───────────────────────────────────────────────────────────
echo ">>> [common] 載入核心模組 overlay / br_netfilter"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# ── 5. 設定核心網路參數 ───────────────────────────────────────────────────────
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q

# ── 6. 安裝 containerd（使用 Docker 官方 repo 以確保跨版本相容性）────────────
echo ">>> [common] 安裝 containerd"
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# 自動偵測 Ubuntu codename
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-$(echo $VERSION_ID | tr '.' '_')}")
echo ">>> [common] Ubuntu codename: ${CODENAME}"

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -q
apt-get install -y -q containerd.io

# 產生預設設定並啟用 SystemdCgroup
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
echo ">>> [common] containerd 安裝完成"

# ── 7. 安裝 kubeadm / kubelet / kubectl ──────────────────────────────────────
echo ">>> [common] 新增 Kubernetes apt 套件庫 (v${K8S_VERSION})"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

apt-get update -q
apt-get install -y -q kubeadm kubelet kubectl
apt-mark hold kubeadm kubelet kubectl

# ── 8. 設定 kubelet 節點 IP（避免 VirtualBox NAT 介面被誤認為主要 IP）────────
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" | tee /etc/default/kubelet > /dev/null

systemctl enable kubelet

echo ">>> [common] 節點 ${NODE_IP} 初始化完成"
