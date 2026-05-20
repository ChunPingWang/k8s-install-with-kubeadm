# 使用 kubeadm 安裝 Kubernetes 叢集（Ubuntu 26.04 Server）

本指南說明如何在 Ubuntu 26.04 LTS Server 上，使用 kubeadm 建立三節點 Kubernetes 叢集。

提供兩種安裝方式：
- **方法一：Vagrant 自動化安裝**（推薦，適合本地開發測試）
- **方法二：手動逐步安裝**（適合正式環境或學習每個步驟）

---

## 方法一：Vagrant + VirtualBox 自動化安裝

### 前置需求

- [VirtualBox](https://www.virtualbox.org/) 7.x
- [Vagrant](https://www.vagrantup.com/) 2.4+
- 主機需有至少 **10GB 可用記憶體**（Master 4GB + 2x Worker 2GB + 主機 OS 保留）
- 主機需有至少 **50GB 可用磁碟空間**

### 目錄結構

```
.
├── Vagrantfile
├── README.md
└── scripts/
    ├── common.sh   # 所有節點共用（containerd、kubeadm、kubelet、kubectl）
    ├── master.sh   # Master 節點初始化與 Flannel 部署
    └── worker.sh   # Worker 節點加入叢集
```

### 快速啟動

```bash
# 複製本專案
git clone https://github.com/ChunPingWang/k8s-install-with-kubeadm.git
cd k8s-install-with-kubeadm

# 啟動全部節點（約 15-25 分鐘）
vagrant up

# 驗證叢集狀態（在 master 上執行）
vagrant ssh k8s-master
kubectl get nodes -o wide
kubectl get pods -A
```

### 常用 Vagrant 指令

| 指令 | 說明 |
|------|------|
| `vagrant up` | 啟動並佈建所有節點 |
| `vagrant up k8s-master` | 僅啟動 master |
| `vagrant ssh k8s-master` | SSH 進入 master |
| `vagrant ssh k8s-worker1` | SSH 進入 worker1 |
| `vagrant halt` | 關閉所有節點 |
| `vagrant destroy -f` | 刪除所有節點 |
| `vagrant status` | 查看節點狀態 |

### 注意事項

1. **Vagrant Box**：預設使用 `bento/ubuntu-26.04`。若該 box 尚未發布，可在 `Vagrantfile` 第一行修改為 `bento/ubuntu-24.04`。
2. **佈建順序**：Vagrant 依定義順序依序佈建（master → worker1 → worker2），Worker 腳本會自動等待 Master 完成。
3. **VirtualBox Host-only 網路**：VirtualBox 6.1.28+ 預設允許 `192.168.56.0/21` 網段，本指南使用的 IP（192.168.56.10-12）在此範圍內。
4. **重新佈建**：若需重建叢集，執行 `vagrant destroy -f && vagrant up`。

---

## 方法二：手動逐步安裝

## 環境需求

| 主機名稱 | IP 位址 | 記憶體 |
|---------|---------|--------|
| k8s-master | 192.168.56.10 | 4GB |
| k8s-worker1 | 192.168.56.11 | 2GB |
| k8s-worker2 | 192.168.56.12 | 2GB |

**前置條件：**
- 三台機器可互相通訊
- 需要網際網路存取
- 使用雲端 VM 時，需開放節點間任意連接埠

---

## 一、所有節點共同設定（master + worker 均需執行）

### 1. 停用 Swap

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### 2. 安裝必要工具

```bash
sudo apt-get update
sudo apt-get install -y vim jq iputils-ping net-tools curl apt-transport-https ca-certificates gnupg
```

### 3. 停用 UFW 防火牆

```bash
sudo ufw disable
```

### 4. 載入必要的核心模組

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### 5. 設定核心參數

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 6. 安裝 containerd

Ubuntu 26.04 的官方套件庫已內建 containerd，可直接安裝：

```bash
sudo apt-get update
sudo apt-get install -y containerd
```

產生預設設定檔並啟用 SystemdCgroup：

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

確認 containerd 運行正常：

```bash
sudo systemctl status containerd
```

### 7. 安裝 kubeadm、kubelet、kubectl

新增 Kubernetes apt 套件庫（以 v1.32 為例）：

```bash
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
```

查看可用版本：

```bash
sudo apt list -a kubeadm
```

安裝指定版本（全部節點使用相同版本）：

```bash
VERSION=1.32.3-1.1
sudo apt-get install -y kubeadm=$VERSION kubelet=$VERSION kubectl=$VERSION
sudo apt-mark hold kubeadm kubelet kubectl
```

確認安裝成功：

```bash
kubeadm version
kubelet --version
kubectl version --client=true
```

---

## 二、初始化 Master 節點（僅在 master 執行）

### 1. 預先下載映像檔（可選）

```bash
sudo kubeadm config images pull
```

預期下載的映像檔：
- kube-apiserver:v1.32.x
- kube-controller-manager:v1.32.x
- kube-scheduler:v1.32.x
- kube-proxy:v1.32.x
- coredns
- pause
- etcd

### 2. 初始化叢集

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.56.10 \
  --pod-network-cidr=10.244.0.0/16
```

參數說明：
- `--apiserver-advertise-address`：Master 節點的 IP，供 Worker 節點連線用
- `--pod-network-cidr`：Pod 網路位址範圍（Flannel 預設使用 10.244.0.0/16）

### 3. 設定 kubectl 存取

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

若以 root 登入：

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

### 4. 啟用 kubectl 自動補全

```bash
source <(kubectl completion bash)
echo "source <(kubectl completion bash)" >> ~/.bashrc
```

---

## 三、部署 Pod 網路（Flannel）

### 1. 下載 Flannel 設定檔

```bash
curl -LO https://github.com/flannel-io/flannel/releases/download/v0.25.5/kube-flannel.yml
```

### 2. 修改設定檔

確認 `net-conf.json` 中的 Network 與 `--pod-network-cidr` 一致：

```yaml
net-conf.json: |
  {
    "Network": "10.244.0.0/16",
    "Backend": {
      "Type": "vxlan"
    }
  }
```

在 DaemonSet 的 `args` 中指定網路介面（依實際介面名稱調整，可用 `ip link` 查詢）：

```yaml
- name: kube-flannel
  image: docker.io/flannel/flannel:v0.25.5
  command:
  - /opt/bin/flanneld
  args:
  - --ip-masq
  - --kube-subnet-mgr
  - --iface=enp0s8
```

> **注意：** Ubuntu 26.04 的網路介面名稱可能有所不同，請執行 `ip link` 確認後填入正確介面名稱。

### 3. 套用 Flannel

```bash
kubectl apply -f kube-flannel.yml
```

### 4. 確認部署狀態

```bash
kubectl get pods -A
kubectl get node -o wide
```

所有 Pod 狀態應為 `Running`，節點狀態應為 `Ready`。

---

## 四、加入 Worker 節點

### 1. 執行加入指令（在每台 Worker 執行）

初始化完成後，master 會輸出類似以下的指令：

```bash
sudo kubeadm join 192.168.56.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

### 2. 若忘記 Join 指令

在 master 重新取得 token：

```bash
kubeadm token list
```

重新取得 CA 憑證雜湊值：

```bash
openssl x509 -in /etc/kubernetes/pki/ca.crt -pubkey -noout | \
  openssl pkey -pubin -outform DER | \
  openssl dgst -sha256
```

### 3. 為 Worker 節點標記角色

```bash
kubectl label node k8s-worker1 node-role.kubernetes.io/worker=worker
kubectl label node k8s-worker2 node-role.kubernetes.io/worker=worker
```

---

## 五、修正節點 Internal IP（若顯示不正確）

若 `kubectl get node -o wide` 顯示的 `INTERNAL-IP` 不正確，在各節點修改 kubelet 設定：

```bash
sudo vim /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
```

在 `ExecStart` 的參數中加入：

```
--node-ip=192.168.56.XX
```

（`XX` 依各節點實際 IP 填入）

```bash
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

---

## 六、驗證叢集狀態

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

預期結果：
- 所有節點狀態為 `Ready`
- 每個節點各有一個 `flannel` DaemonSet Pod
- 每個節點各有一個 `kube-proxy` Pod
- `coredns` Pod 正常運行
- Control plane Pod（api-server、scheduler、controller-manager、etcd）均正常

---

## 參考資料

- [Kubernetes 官方文件 - kubeadm 安裝](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [原始教學文件](https://learn-k8s-from-scratch.readthedocs.io/en/latest/k8s-install/kubeadm.html)
- [Flannel 網路插件](https://github.com/flannel-io/flannel)
- [containerd 官方文件](https://containerd.io/)
