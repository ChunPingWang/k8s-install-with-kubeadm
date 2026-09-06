#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  master.sh — Control Plane 節點初始化
# ═══════════════════════════════════════════════════════════════════════════
#
#  需求（Requirements）
#  ─────────────────────────────────────────────────────────────────────────
#  R1  建立單一 control plane 叢集，apiserver 對外位址固定為 host-only IP
#  R2  Pod 之間跨節點可直接互通（CNI）
#  R3  vagrant 使用者一登入就能直接用 kubectl，不必手動設 KUBECONFIG
#  R4  產生一份 worker 可取用的 join 指令
#  R5  可重複執行：vagrant provision 重跑不得毀掉已存在的叢集
#
#  設計決策（Design Decisions）
#  ─────────────────────────────────────────────────────────────────────────
#  D1  【--apiserver-advertise-address 指定 host-only IP】不指定的話 kubeadm
#      會挑預設路由的介面，也就是 VirtualBox NAT 的 10.0.2.15。憑證會簽在那個
#      位址上，worker 與 host 都連不到，且錯誤會延遲到 join 階段才爆。
#
#  D2  【Flannel 而非 Calico】本專案的目的是「看懂網路怎麼運作」。
#      Flannel 的 VXLAN 後端只有一層封裝、路由規則用 ip route 就看得完，
#      對照 README 的網路原理章節剛好可以一條一條驗證。
#      代價：Flannel 不實作 NetworkPolicy —— NetworkPolicy 章節的實驗需要
#      另外換成 Calico/Cilium，這是刻意接受的取捨。
#
#  D3  【明確傳 --iface 給 flanneld】節點有兩張網卡（NAT + host-only）。
#      flanneld 自動選介面時會選到 NAT，於是 VXLAN 的外層目的位址是各節點
#      都相同的 10.0.2.15 → 跨節點 Pod 流量整包送不出去。
#      這裡從「IP 屬於 192.168.56.0/24 的介面」反推名稱，不寫死 enp0s8，
#      因為介面命名會隨 box 與 VirtualBox 版本改變。
#
#  D4  【pod-network-cidr 必須與 CNI 的設定一致】kubeadm 用它決定發給每個節點
#      的 PodCIDR，Flannel 用 net-conf.json 的 Network 決定自己的位址空間。
#      兩者不一致時 Pod 拿得到 IP、但路由永遠對不上。本腳本會實際比對下載
#      到的 manifest（見 P2），不靠「記得它是 10.244.0.0/16」。
#
#  D5  【join 指令透過 synced folder 傳遞】/vagrant 是三台 VM 唯一的共享媒介。
#      先寫暫存檔再 mv，避免 worker 讀到寫到一半的內容。
#      token 預設效期 24 小時；隔天才開 worker 會拿到過期的 token，
#      屆時重跑 `vagrant provision k8s-master` 即可換發（本腳本每次都會換發）。
#
#  D6  【不對 /vagrant 上的檔案 chmod +x】vboxsf 的權限由 mount 選項決定，
#      chmod 在部分 host 上會失敗；在 set -e 之下那會讓整個 provisioning 中斷。
#      worker 端一律用 `bash <file>` 執行，執行位元本來就不需要。
#
#  原則（Principles）
#  ─────────────────────────────────────────────────────────────────────────
#  P1  破壞性動作先檢查現況：kubeadm init 只在叢集尚未存在時執行。
#  P2  不信任外部檔案的內容，下載後先驗證再使用。
#  P3  寫進使用者的 dotfile 前先確認還沒寫過，重跑不留重複行。
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

MASTER_IP="${MASTER_IP:?MASTER_IP 未設定（應由 Vagrantfile 的 provision env 傳入）}"
POD_CIDR="10.244.0.0/16"
FLANNEL_VERSION="v0.25.5"   # 刻意釘選版本（見 README「版本釘選」原則）

echo ">>> [master] 初始化 Master 節點 IP=${MASTER_IP}"

# ── 1. 預先下載 K8s 映像檔 ────────────────────────────────────────────────────
# 分開做的用意：把「拉映像」與「初始化」的失敗分離。網路慢造成的逾時會在這裡
# 顯現，而不是混在 kubeadm init 的錯誤裡難以判讀。
echo ">>> [master] 預先下載 Kubernetes 映像檔"
kubeadm config images pull

# ── 2. 初始化叢集 ─────────────────────────────────────────────────────────────
# 冪等保護（P1）：admin.conf 存在代表叢集已經初始化過。
# 在既有叢集上重跑 kubeadm init 會因為 port/檔案已佔用而失敗，
# 更糟的情況是留下半毀的 control plane。
if [ -f /etc/kubernetes/admin.conf ]; then
  echo ">>> [master] 偵測到 /etc/kubernetes/admin.conf，叢集已存在，略過 kubeadm init"
  echo "    （要重建請先執行 vagrant destroy，或在節點上 kubeadm reset）"
else
  echo ">>> [master] 執行 kubeadm init"
  kubeadm init \
    --apiserver-advertise-address="${MASTER_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name="$(hostname)" \
    --ignore-preflight-errors=NumCPU 2>&1 | tee /tmp/kubeadm-init.log
fi

# ── 3. 設定 kubectl（vagrant 使用者）─────────────────────────────────────────
echo ">>> [master] 設定 kubectl"
install -d -o vagrant -g vagrant -m 0700 /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config
chmod 0600 /home/vagrant/.kube/config   # 這份憑證等同 cluster-admin

# 本腳本後續的 kubectl 都用 root 的 admin.conf
export KUBECONFIG=/etc/kubernetes/admin.conf

# 永久設定（P3：先確認沒寫過，避免 vagrant provision 重跑時累積重複行）
add_line_once() {
  local line="$1" file="$2"
  grep -qxF -- "${line}" "${file}" 2>/dev/null || echo "${line}" >> "${file}"
}
add_line_once "export KUBECONFIG=/etc/kubernetes/admin.conf" /root/.bashrc
add_line_once "source <(kubectl completion bash)"            /root/.bashrc
add_line_once "export KUBECONFIG=/home/vagrant/.kube/config" /home/vagrant/.bashrc
add_line_once "source <(kubectl completion bash)"            /home/vagrant/.bashrc

# ── 4. 安裝 Flannel CNI ───────────────────────────────────────────────────────
echo ">>> [master] 安裝 Flannel ${FLANNEL_VERSION}"

curl -fsSL \
  "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" \
  -o /tmp/kube-flannel.yml

# 驗證下載內容與 kubeadm 的 pod-network-cidr 一致（P2 / D4）
if ! grep -q "\"Network\": \"${POD_CIDR}\"" /tmp/kube-flannel.yml; then
  echo "錯誤：Flannel manifest 的 Network 與 --pod-network-cidr (${POD_CIDR}) 不一致" >&2
  grep -n '"Network"' /tmp/kube-flannel.yml >&2 || true
  echo "      請同步調整本腳本的 POD_CIDR，或改用相符的 Flannel 版本" >&2
  exit 1
fi

# 偵測 Host-only 介面（IP 為 192.168.56.x 的介面），見 D3
FLANNEL_IFACE=$(ip -o addr show | awk '/192\.168\.56\./ {print $2}' | head -1)
if [ -z "${FLANNEL_IFACE}" ]; then
  echo "錯誤：找不到 192.168.56.0/24 網段的網路介面" >&2
  ip -o addr show >&2
  exit 1
fi
echo ">>> [master] Flannel 使用介面: ${FLANNEL_IFACE}"

# 在 kube-flannel container 的 args 後面補上 --iface。
# 用 sed 的 0,/re/ 位址範圍只改「第一次出現」，避免波及 install-cni 等其他容器。
# （已對 v0.25.5 的 manifest 驗證過：--kube-subnet-mgr 全檔只出現一次）
sed -i "0,/^        - --kube-subnet-mgr\$/s//&\n        - --iface=${FLANNEL_IFACE}/" \
  /tmp/kube-flannel.yml

# 斷言（P2）：sed 沒比對到時 exit code 一樣是 0，不檢查就會靜默地用錯介面
if ! grep -q -- "- --iface=${FLANNEL_IFACE}" /tmp/kube-flannel.yml; then
  echo "錯誤：未能在 Flannel manifest 中插入 --iface 參數" >&2
  echo "      可能是 ${FLANNEL_VERSION} 的 manifest 格式有變，請檢查 args 區塊縮排" >&2
  exit 1
fi

kubectl apply -f /tmp/kube-flannel.yml

# ── 5. 等待 CoreDNS 就緒 ──────────────────────────────────────────────────────
# CoreDNS 要等到 CNI 就緒才排得上去，所以它 Ready 等於「Pod 網路通了」。
# 這裡不強制成功：worker 就算在 DNS 起來之前 join 也沒問題，
# 讓 provisioning 卡死在這裡反而更難排查。
echo ">>> [master] 等待 CoreDNS Pod 就緒（最多 3 分鐘）"
kubectl -n kube-system wait \
  --for=condition=Ready pod \
  --selector=k8s-app=kube-dns \
  --timeout=180s || echo "警告：CoreDNS 尚未就緒，Worker 仍可加入"

# ── 6. 產生 Join 指令給 Worker 節點（見 D5）──────────────────────────────────
# 每次 provisioning 都換發新 token，因此 token 過期時只要重跑
#   vagrant provision k8s-master
# 就能讓後續的 worker 正常加入。
echo ">>> [master] 產生 join-command.sh"
kubeadm token create --print-join-command > /vagrant/.join-command.tmp
mv /vagrant/.join-command.tmp /vagrant/join-command.sh   # 先寫暫存再 mv，避免半成品被讀走

echo ""
echo "=========================================="
echo " Master 初始化完成"
echo " Join 指令已存至 /vagrant/join-command.sh"
echo " （內含有效 token，效期 24 小時，已列入 .gitignore）"
echo "=========================================="
kubectl get nodes -o wide
