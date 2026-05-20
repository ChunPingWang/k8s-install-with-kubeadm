#!/bin/bash
# Master 節點初始化腳本
set -euo pipefail

MASTER_IP="${MASTER_IP}"
POD_CIDR="10.244.0.0/16"
FLANNEL_VERSION="v0.25.5"

echo ">>> [master] 初始化 Master 節點 IP=${MASTER_IP}"

# ── 1. 預先下載 K8s 映像檔 ────────────────────────────────────────────────────
echo ">>> [master] 預先下載 Kubernetes 映像檔"
kubeadm config images pull

# ── 2. 初始化叢集 ─────────────────────────────────────────────────────────────
echo ">>> [master] 執行 kubeadm init"
kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --node-name="$(hostname)" \
  --ignore-preflight-errors=NumCPU 2>&1 | tee /tmp/kubeadm-init.log

# ── 3. 設定 kubectl（vagrant 使用者）─────────────────────────────────────────
echo ">>> [master] 設定 kubectl"
mkdir -p /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config

# root 也可以使用
export KUBECONFIG=/etc/kubernetes/admin.conf

# 永久設定 KUBECONFIG 環境變數（root 與 vagrant 皆可用）
echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /root/.bashrc
echo "export KUBECONFIG=/home/vagrant/.kube/config" >> /home/vagrant/.bashrc
echo "source <(kubectl completion bash)"             >> /home/vagrant/.bashrc

# ── 4. 安裝 Flannel CNI ───────────────────────────────────────────────────────
echo ">>> [master] 安裝 Flannel ${FLANNEL_VERSION}"

curl -fsSL \
  "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" \
  -o /tmp/kube-flannel.yml

# 偵測 Host-only 介面（IP 為 192.168.56.x 的介面）
FLANNEL_IFACE=$(ip -o addr show | awk '/192\.168\.56\./ {print $2}' | head -1)
echo ">>> [master] Flannel 使用介面: ${FLANNEL_IFACE}"

# 在 DaemonSet args 中加入 --iface 參數
python3 - <<PYEOF
with open('/tmp/kube-flannel.yml', 'r') as f:
    content = f.read()

iface = '${FLANNEL_IFACE}'
old = '        - --kube-subnet-mgr'
new = old + '\n        - --iface=' + iface

# 只替換第一次出現（kube-flannel container），避免影響其他區塊
content = content.replace(old, new, 1)

with open('/tmp/kube-flannel.yml', 'w') as f:
    f.write(content)

print(f'Flannel iface set to: {iface}')
PYEOF

kubectl apply -f /tmp/kube-flannel.yml

# ── 5. 等待 CoreDNS 就緒 ──────────────────────────────────────────────────────
echo ">>> [master] 等待 CoreDNS Pod 就緒（最多 3 分鐘）"
kubectl -n kube-system wait \
  --for=condition=Ready pod \
  --selector=k8s-app=kube-dns \
  --timeout=180s || echo "警告：CoreDNS 尚未就緒，Worker 仍可加入"

# ── 6. 產生 Join 指令給 Worker 節點 ──────────────────────────────────────────
echo ">>> [master] 產生 join-command.sh"
kubeadm token create --print-join-command > /vagrant/join-command.sh
chmod +x /vagrant/join-command.sh

echo ""
echo "=========================================="
echo " Master 初始化完成"
echo " Join 指令已存至 /vagrant/join-command.sh"
echo "=========================================="
kubectl get nodes -o wide
