#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  common.sh — 所有節點（master + worker）共用的初始化腳本（Ubuntu 24.04）
# ═══════════════════════════════════════════════════════════════════════════
#
#  需求（Requirements）
#  ─────────────────────────────────────────────────────────────────────────
#  R1  把一台乾淨的 Ubuntu 24.04 變成「可以被 kubeadm 接管」的節點
#  R2  master 與 worker 的節點層設定必須完全一致（避免 cgroup / 網路行為飄移）
#  R3  可重複執行：vagrant provision 重跑不得破壞既有節點
#  R4  版本可重現：套件版本不得在使用者不知情下漂移
#
#  設計決策（Design Decisions）
#  ─────────────────────────────────────────────────────────────────────────
#  D1  【containerd 取自 Docker 官方 repo，而非 Ubuntu universe】
#      Docker repo 對每個 Ubuntu 版本都同步供貨，且緊跟 containerd 上游；
#      Ubuntu 內建的版本會隨發行版凍結，換 box 版本時行為就會變。
#      注意：目前該 repo 的 containerd.io 已是 2.x，設定檔為 version = 3
#      格式（plugin key 從 io.containerd.grpc.v1.cri 改為 io.containerd.cri.v1.*）。
#      本腳本的所有 sed 都不綁定 plugin 區塊名稱，因此 1.x / 2.x 皆適用。
#
#  D2  【SystemdCgroup = true】Ubuntu 24.04 是 cgroup v2 + systemd。
#      kubelet 預設用 systemd driver，若 runtime 還停在 cgroupfs，兩邊會各自
#      管理同一組 cgroup → 節點在負載升高時隨機 NotReady，而且症狀極難歸因。
#      這是「兩個元件必須講好同一件事」的設定，不是效能調校。
#
#  D3  【apt-mark hold】叢集元件不接受 unattended-upgrades 隨機升級。
#      Kubernetes 的升級有嚴格順序（kubeadm → control plane → kubelet），
#      而且一次只能跨一個 minor 版本；被自動升級打斷會直接壞掉。
#
#  D4  【--node-ip 明確指定】VirtualBox 的第一張網卡是 NAT，三台機器上都是
#      10.0.2.15。kubelet 若自動選 IP 會挑到它，於是三個節點的 InternalIP
#      全部相同 → apiserver 連不到 kubelet（logs / exec 全掛）、Flannel 路由錯亂。
#
#  D5  【swap 用容忍空白字元的 regex 關閉】Ubuntu 24.04 的 /etc/fstab 是用
#      TAB 分隔（/swap.img<TAB>none<TAB>swap...）。只比對 " swap " 會漏掉，
#      當下 swapoff -a 有效、重開機後 swap 又回來 → kubelet 起不來。
#
#  D6  【對齊 pause 映像】kubeadm 與 containerd 各自有預設的 pause 版本
#      （kubeadm 1.32 用 3.10；containerd 2.3 用 3.10.2）。不對齊時
#      kubeadm config images pull 預抓的那顆不會被用到，離線／慢速網路
#      環境會在建立第一個 Pod 時卡住。
#
#  原則（Principles）
#  ─────────────────────────────────────────────────────────────────────────
#  P1  fail fast：set -euo pipefail。provisioning 失敗要當場停，不要留下
#      「看起來成功、其實半殘」的節點。
#  P2  設定完就驗證：每個關鍵設定後面都跟一個斷言。sed 沒改到東西時
#      exit code 仍是 0，沉默的失敗比壞掉更貴。
#  P3  冪等：重跑一次的結果要和跑一次相同。
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

# 未帶入必要變數時直接失敗（P1）：這兩個值由 Vagrantfile 的 provision env 提供
NODE_IP="${NODE_IP:?NODE_IP 未設定（應由 Vagrantfile 的 provision env 傳入）}"
K8S_VERSION="${K8S_VERSION:-1.32}"

echo ">>> [common] 開始初始化節點 IP=${NODE_IP}, K8s=${K8S_VERSION}"

# ── 1. 停用 Swap ──────────────────────────────────────────────────────────────
# kubelet 預設 failSwapOn=true。原因：scheduler 依「可用記憶體」做決策，
# swap 會讓 Pod 在記憶體超賣時被拖慢而不是被 OOMKill，QoS 保證形同虛設。
echo ">>> [common] 停用 swap"
swapoff -a
# 只註解「尚未被註解」且欄位含 swap 的行；容忍 space 與 TAB（見 D5），重跑不疊加 #
sed -i -E '/^[[:space:]]*#/! s/^(.*[[:space:]]swap[[:space:]].*)$/#\1/' /etc/fstab

# 斷言（P2）：確認記憶體中已無 swap
if [ "$(swapon --show --noheadings | wc -l)" -ne 0 ]; then
  echo "錯誤：swap 仍在啟用中" >&2
  swapon --show >&2
  exit 1
fi

# ── 2. 安裝基本工具 ───────────────────────────────────────────────────────────
echo ">>> [common] 安裝基本工具"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
  vim jq curl wget \
  iputils-ping net-tools \
  apt-transport-https ca-certificates gnupg \
  software-properties-common

# ── 3. 停用 UFW ───────────────────────────────────────────────────────────────
# 教學／實驗環境的取捨：kube-proxy 與 CNI 會大量操作 iptables/nftables，
# UFW 的規則會與之互相干擾且極難除錯。正式環境請改為只開必要埠
# （6443 / 2379-2380 / 10250 / 10256 / 8472-UDP），而不是整個關掉。
echo ">>> [common] 停用 UFW"
ufw disable || true   # box 內可能根本沒裝 ufw，不視為錯誤

# ── 4. 載入核心模組 ───────────────────────────────────────────────────────────
# overlay      : containerd 的預設 snapshotter（overlayfs）需要
# br_netfilter : 讓「走 Linux bridge 的封包」也會經過 iptables
#                → kube-proxy 的 Service DNAT、NetworkPolicy 才會生效
echo ">>> [common] 載入核心模組 overlay / br_netfilter"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# ── 5. 設定核心網路參數 ───────────────────────────────────────────────────────
# ip_forward  : 節點要幫 Pod 轉送封包（跨節點流量、Service 轉發）
# bridge-nf-* : 搭配 br_netfilter，同上
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q

# 斷言（P2）
for kv in "net.ipv4.ip_forward=1" "net.bridge.bridge-nf-call-iptables=1"; do
  key="${kv%=*}"
  want="${kv#*=}"
  got="$(sysctl -n "${key}")"
  if [ "${got}" != "${want}" ]; then
    echo "錯誤：${key} 期望 ${want}，實際 ${got}" >&2
    exit 1
  fi
done

# ── 6. 安裝 containerd（使用 Docker 官方 repo，見 D1）────────────────────────
echo ">>> [common] 安裝 containerd"
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# 自動偵測 Ubuntu codename（換 box 版本時不必改腳本）
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-$(echo "$VERSION_ID" | tr '.' '_')}")
echo ">>> [common] Ubuntu codename: ${CODENAME}"

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -q
apt-get install -y -q containerd.io

# 產生預設設定並啟用 SystemdCgroup（見 D2）
# 註：containerd.io 套件預設會寫一份 disabled_plugins = ["cri"] 的設定，
#     必須整份換成 config default，CRI 介面才會啟用。
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 斷言（P2）：sed 找不到目標時不會報錯，只會什麼都沒改
if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
  echo "錯誤：containerd 設定中找不到 SystemdCgroup = true" >&2
  echo "      containerd 版本：$(containerd --version)" >&2
  echo "      可能是上游改了設定鍵名，請檢查 /etc/containerd/config.toml" >&2
  exit 1
fi

systemctl restart containerd
systemctl enable containerd
echo ">>> [common] containerd 安裝完成（$(containerd --version)）"

# ── 7. 安裝 kubeadm / kubelet / kubectl ──────────────────────────────────────
echo ">>> [common] 新增 Kubernetes apt 套件庫 (v${K8S_VERSION})"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

apt-get update -q
apt-get install -y -q kubeadm kubelet kubectl
apt-mark hold kubeadm kubelet kubectl   # 見 D3

# ── 8. 讓 containerd 與 kubeadm 用同一顆 pause 映像（見 D6）──────────────────
# 必須排在 kubeadm 安裝之後：pause 版本要問 kubeadm 才知道。
PAUSE_IMAGE="$(kubeadm config images list 2>/dev/null | grep -m1 '/pause:' || true)"
if [ -n "${PAUSE_IMAGE}" ]; then
  echo ">>> [common] 對齊 pause 映像：${PAUSE_IMAGE}"
  # containerd 2.x：[plugins.'io.containerd.cri.v1.images'.pinned_images] → sandbox = '...'
  sed -i -E "s|^([[:space:]]*sandbox[[:space:]]*=[[:space:]]*).*$|\1'${PAUSE_IMAGE}'|" \
    /etc/containerd/config.toml
  # containerd 1.x：[plugins.\"io.containerd.grpc.v1.cri\"] → sandbox_image = \"...\"
  sed -i -E "s|^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*$|\1'${PAUSE_IMAGE}'|" \
    /etc/containerd/config.toml
  if grep -q "${PAUSE_IMAGE}" /etc/containerd/config.toml; then
    systemctl restart containerd
  else
    echo "警告：未能寫入 pause 映像設定，將沿用 containerd 預設值" >&2
  fi
else
  echo "警告：無法從 kubeadm 取得 pause 映像名稱，沿用 containerd 預設值" >&2
fi

# ── 9. 設定 crictl 的 runtime endpoint ───────────────────────────────────────
# 不設的話 crictl 每次都會印一長串警告並輪流探測多個 socket，
# 在排查節點問題時非常干擾（README 疑難排解章節會用到 crictl）。
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# ── 10. 設定 kubelet 節點 IP（見 D4）─────────────────────────────────────────
# 用 > 而非 >>：這個檔案由本腳本全權擁有，重跑時直接覆寫，不累積重複行。
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet

systemctl enable kubelet
# 註：此處刻意不 start kubelet。它要等 kubeadm init/join 產生 kubeconfig
#     與設定檔之後才有辦法正常運作，現在啟動只會進入 crash loop。

echo ">>> [common] 節點 ${NODE_IP} 初始化完成"
