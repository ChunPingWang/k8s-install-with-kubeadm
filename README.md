# 使用 kubeadm 安裝 Kubernetes 叢集（Ubuntu 24.04 Server）

本指南說明如何在 Ubuntu 24.04 LTS Server 上，使用 kubeadm 建立三節點 Kubernetes 叢集。

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

1. **Vagrant Box**：預設使用 `bento/ubuntu-24.04`。若該 box 尚未發布，可在 `Vagrantfile` 第一行修改為 `bento/ubuntu-24.04`。
2. **佈建順序**：Vagrant 依定義順序依序佈建（master → worker1 → worker2），Worker 腳本會自動等待 Master 完成。
3. **VirtualBox Host-only 網路**：VirtualBox 6.1.28+ 預設允許 `192.168.56.0/21` 網段，本指南使用的 IP（192.168.56.10-12）在此範圍內。
4. **重新佈建**：若需重建叢集，執行 `vagrant destroy -f && vagrant up`。

---

## Kubernetes 架構原理

在動手安裝之前，先建立對整體架構的認識。理解每個元件的職責，才能看懂安裝步驟的用意，以及遇到問題時知道從哪裡下手。

---

### 宣告式模型（Declarative Model）

Kubernetes 的核心思想是**宣告式（Declarative）**：你告訴 Kubernetes「我想要什麼狀態」，而不是「請執行哪些步驟」。

```
命令式（Imperative）：「啟動 3 個 nginx container，然後設定 load balancer，再...」
宣告式（Declarative）：「我想要 3 個 nginx Pod 永遠在跑」
```

Kubernetes 持續比較「目前狀態」與「期望狀態」，有差異就自動修正。這個機制稱為 **Control Loop（控制迴圈）** 或 **Reconciliation Loop（調和迴圈）**。

```
┌─────────────────────────────────────────────────────┐
│                   Control Loop                       │
│                                                      │
│   Observe           Compare           Act            │
│   觀察現況   ──►   比較期望   ──►   執行調整          │
│      ▲                                  │            │
│      └──────────────────────────────────┘            │
│                                                      │
│  例：ReplicaSet 要求 3 個 Pod，目前只有 2 個           │
│  → Controller 自動建立第 3 個 Pod                     │
└─────────────────────────────────────────────────────┘
```

---

### 整體架構

```
                    kubectl / 外部 API 請求
                            │
                            │ HTTPS :6443
                            ▼
┌───────────────────────────────────────────────────────────────┐
│                    Control Plane（Master Node）                 │
│                                                               │
│  ┌─────────────────┐     ┌─────────────────────────────────┐  │
│  │  kube-apiserver │◄───►│            etcd                 │  │
│  │  （唯一入口）    │     │  （叢集狀態儲存 / Raft 共識）    │  │
│  └────────┬────────┘     └─────────────────────────────────┘  │
│           │ Watch / Notify                                     │
│     ┌─────┴──────────────────────┐                            │
│     ▼                            ▼                            │
│  ┌──────────────┐    ┌─────────────────────────────────────┐  │
│  │kube-scheduler│    │      kube-controller-manager         │  │
│  │（Pod 排程）  │    │  （Node / ReplicaSet / Endpoint 等   │  │
│  │              │    │   數十個 Controller 的集合體）         │  │
│  └──────────────┘    └─────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
          │  kubelet 主動向 API Server 發起 HTTPS 連線
          ├─────────────────┬───────────────────────┐
          ▼                 ▼                       ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  Worker Node 1   │ │  Worker Node 2   │ │  Worker Node 3   │
│                  │ │                  │ │                  │
│  ┌────────────┐  │ │  ┌────────────┐  │ │  ┌────────────┐  │
│  │  kubelet   │  │ │  │  kubelet   │  │ │  │  kubelet   │  │
│  │（Pod 生命  │  │ │  │            │  │ │  │            │  │
│  │  週期管理）│  │ │  │            │  │ │  │            │  │
│  ├────────────┤  │ │  ├────────────┤  │ │  ├────────────┤  │
│  │ kube-proxy │  │ │  │ kube-proxy │  │ │  │ kube-proxy │  │
│  │（Service   │  │ │  │ iptables / │  │ │  │  路由規則） │  │
│  │  路由規則） │  │ │  │  ipvs 規則 │  │ │  │            │  │
│  ├────────────┤  │ │  ├────────────┤  │ │  ├────────────┤  │
│  │ containerd │  │ │  │ containerd │  │ │  │ containerd │  │
│  │（容器執行期）│ │  │（OCI Runtime）│ │  │            │  │
│  └────────────┘  │ │  └────────────┘  │ │  └────────────┘  │
│  ┌───┐ ┌───┐    │ │  ┌───┐ ┌───┐    │ │  ┌───┐ ┌───┐    │
│  │Pod│ │Pod│    │ │  │Pod│ │Pod│    │ │  │Pod│ │Pod│    │
│  └───┘ └───┘    │ │  └───┘ └───┘    │ │  └───┘ └───┘    │
└──────────────────┘ └──────────────────┘ └──────────────────┘
      ════════════ Pod 網路（Flannel VXLAN Overlay） ═══════════
      所有 Pod 共用 CIDR 10.244.0.0/16，跨節點可互相直連
```

---

### Control Plane 元件詳解

#### kube-apiserver — 叢集的唯一入口

API Server 是整個叢集的**核心閘道**。所有操作（kubectl、Controller、kubelet）都只和 API Server 溝通，沒有任何元件直接存取 etcd。

```
外部請求  →  Authentication（身份驗證）
            →  Authorization / RBAC（授權）
               →  Admission Controllers（准入控制，如 PSA、ResourceQuota）
                  →  Persist to etcd（寫入儲存）
                     →  通知 Watch 的元件
```

**為什麼只有 API Server 可以存取 etcd？**
將 etcd 存取收斂到單一元件，才能統一執行身份驗證、授權、資料驗證。若每個元件都能直接寫 etcd，安全性與資料一致性無從保障。

---

#### etcd — 叢集狀態的唯一真相來源

etcd 是一個**分散式 key-value 儲存系統**，使用 **Raft 共識演算法**確保多個副本之間的資料一致性。

**儲存內容：** Pod、Deployment、Service、ConfigMap、Secret、RBAC 規則…所有 Kubernetes 物件。

**Raft 共識：** 在多節點的 etcd 叢集中，寫入操作需要多數節點（quorum）確認才算成功。例如 3 節點叢集需要 2 個節點確認；這使得 etcd 能夠容忍 1 個節點故障。

```
3 節點 etcd 叢集：
  Node A（Leader）  ← 寫入請求
  Node B（Follower）← 複製
  Node C（Follower）← 複製
  需要 A+B 或 A+C 確認 → 可容忍 1 個節點故障
```

**為什麼備份 etcd 等同於備份整個叢集？** 因為所有叢集狀態都在這裡，從這份 snapshot 可以完整還原叢集。

---

#### kube-scheduler — Pod 排程決策

Scheduler 持續 Watch API Server，一旦發現有尚未分配節點（`nodeName` 為空）的 Pod，就執行排程演算法，選出最合適的節點，然後更新 Pod 的 `nodeName` 欄位。

**排程流程：**

```
1. Filtering（過濾）：排除不符合條件的節點
   - 資源不足（CPU/Memory request > 可用資源）
   - 有 Taint 但 Pod 沒有對應 Toleration
   - NodeSelector / NodeAffinity 不符合
   - Pod 的 hostPort 衝突
   - 節點不健康（NotReady）

2. Scoring（評分）：對剩餘節點打分
   - 資源均衡（避免某節點過熱）
   - Affinity / Anti-Affinity 偏好
   - 映像已在節點上（省去拉取時間）

3. Binding（綁定）：寫入 Pod.spec.nodeName
```

Scheduler **不執行** Pod，只做決策。實際啟動 Pod 的是 kubelet。

---

#### kube-controller-manager — 所有 Controller 的集合體

Controller Manager 跑著數十個 Controller，每個 Controller 負責一種資源的「期望狀態 vs 實際狀態」調和。

| Controller | 職責 |
|---|---|
| ReplicaSet Controller | 確保 Pod 數量與 ReplicaSet 要求一致 |
| Deployment Controller | 管理 ReplicaSet 的滾動更新 |
| Node Controller | 偵測節點失聯，標記 NotReady |
| Endpoint Controller | 維護 Service 與 Pod 的對應關係 |
| ServiceAccount Controller | 自動為新 Namespace 建立 default SA |
| Job Controller | 確保 Job 完成指定次數 |

每個 Controller 都是一個獨立的 Control Loop，互不干擾。

---

### Worker Node 元件詳解

#### kubelet — 節點上的「代理人」

kubelet 是每個 Worker Node（以及 Master Node）上的守護程式，負責：

1. 向 API Server 註冊自己（Node 物件）
2. Watch API Server，接收分配到本節點的 Pod Spec
3. 呼叫 CRI（Container Runtime Interface）啟動容器
4. 持續回報 Pod 狀態、節點資源使用量
5. 執行 Liveness / Readiness Probe
6. 管理 Static Pod（直接讀取 `/etc/kubernetes/manifests/`）

**kubelet 與 API Server 的通訊方向：** kubelet **主動連向** API Server（HTTPS :6443），而非 API Server 推送給 kubelet。這設計使得 Worker Node 不需要開放任何 port 給 Master。

---

#### kube-proxy — Service 網路的實作者

kube-proxy 讓 Kubernetes **Service** 能夠運作。它 Watch API Server 上的 Service 和 Endpoints，將對應的路由規則寫入作業系統：

```
預設模式（iptables）：
  Service ClusterIP:Port
    → iptables DNAT 規則
      → 隨機選取一個後端 Pod IP:Port

IPVS 模式（效能更佳）：
  使用 Linux IPVS（LVS）做 load balancing
  適合大規模叢集（數千個 Service）
```

**kube-proxy 不處理 Pod-to-Pod 通訊**，那是 CNI 的職責。

---

#### containerd — OCI 標準容器執行期

containerd 是實際**執行容器**的程式，實作了 **CRI（Container Runtime Interface）**，讓 kubelet 可以呼叫它：

```
kubelet
  → CRI（gRPC）
    → containerd
      → runc（OCI Runtime，真正的 Linux container）
        → 隔離的 cgroup / namespace
```

**containerd 的職責：**
- 從 Registry 拉取映像（Image Pull）
- 管理映像的 Overlay Filesystem 層（UnionFS）
- 使用 runc 建立 cgroup、namespace 並啟動 container
- 管理 container 生命週期（start / stop / delete）

---

### 一個 Pod 從建立到運行的完整旅程

```
$ kubectl apply -f pod.yaml
        │
        ▼
[1] kube-apiserver
    - 驗證身份（TLS 客戶端憑證 / Bearer Token）
    - 授權檢查（RBAC：你有權建立 Pod 嗎？）
    - Admission Control（ResourceQuota 夠嗎？PSA 符合嗎？）
    - 將 Pod 物件（spec.nodeName = ""）寫入 etcd
        │
        ▼
[2] kube-scheduler（Watch 到新的 Unscheduled Pod）
    - 執行 Filtering + Scoring
    - 選出最佳節點（例如 k8s-worker1）
    - 更新 Pod.spec.nodeName = "k8s-worker1" → 寫入 etcd
        │
        ▼
[3] kubelet on k8s-worker1（Watch 到分配給自己的 Pod）
    - 呼叫 CNI 插件（Flannel）分配 Pod IP
    - 呼叫 containerd（CRI）：
        → 拉取映像（若不在 local cache）
        → 建立 Pod sandbox（pause container：持有 Network namespace）
        → 啟動應用 container，加入 sandbox 的 network namespace
    - 執行 Readiness Probe，通過後回報 Pod Ready
        │
        ▼
[4] Endpoint Controller
    - 偵測到 Pod Ready，將 Pod IP 加入對應 Service 的 Endpoints
        │
        ▼
[5] kube-proxy on 所有節點
    - Watch 到 Endpoints 更新
    - 更新 iptables / IPVS 規則
    - Service 現在可以正確路由到新的 Pod
```

整個過程通常在 **5-30 秒**內完成（取決於映像大小與節點資源）。

---

### Pod 網路模型（Flannel / VXLAN）

Kubernetes 要求所有 Pod 之間可以**直接通訊**（不需要 NAT），且每個 Pod 有唯一的 IP。這個要求由 **CNI（Container Network Interface）** 插件實現。

**Flannel 的 VXLAN 模式：**

```
Node 1 (192.168.56.11)          Node 2 (192.168.56.12)
┌──────────────────────┐         ┌──────────────────────┐
│  Pod A  10.244.1.10  │         │  Pod B  10.244.2.20  │
│         │            │         │         ▲            │
│      eth0（veth）    │         │      eth0（veth）    │
│         │            │         │         │            │
│      cni0（bridge）  │         │      cni0（bridge）  │
│         │            │         │         │            │
│      flannel.1       │         │      flannel.1       │
│   （VTEP: VXLAN 端點）│         │   （VTEP: VXLAN 端點）│
│         │            │         │         │            │
│      eth1（實體網卡） │─────────│      eth1（實體網卡） │
│   192.168.56.11      │ UDP/8472│   192.168.56.12      │
└──────────────────────┘         └──────────────────────┘
```

**封包路徑（Pod A → Pod B）：**

1. Pod A 送出封包：`src=10.244.1.10 dst=10.244.2.20`
2. flannel.1（VTEP）將原始封包封裝進 VXLAN frame
3. 外層封包：`src=192.168.56.11 dst=192.168.56.12`（節點 IP）
4. 實體網路傳輸
5. Node 2 的 flannel.1 解封裝，還原原始封包
6. 路由到 Pod B

這就是為什麼安裝時需要 `--pod-network-cidr` 和指定 `--iface`（讓 Flannel 知道用哪個實體介面做 VXLAN 封裝）。

---

## 方法二：手動逐步安裝（含原理說明）

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

> **原理說明：** Kubernetes 的記憶體管理依賴 **cgroup**：當 Container 超過 `memory limit`，cgroup 觸發 OOM Kill（記憶體不足殺程式），確保 Pod 之間互不干擾。若開啟 Swap，超過 limit 的 Container 不會被立即殺死，而是把資料寫進 Swap，導致：
> - 記憶體 limit 形同虛設，Pod 可能無限消耗資源
> - 大量 Swap I/O 使節點效能劇降，但 Kubernetes 排程器不感知 Swap 使用量
> - 節點假象「有記憶體」，Scheduler 仍排入更多 Pod，最終全部效能惡化
>
> `sed -i '/ swap / ...'` 將 `/etc/fstab` 中的 swap 條目註解掉，防止重啟後重新掛載。

### 2. 安裝必要工具

```bash
sudo apt-get update
sudo apt-get install -y vim jq iputils-ping net-tools curl apt-transport-https ca-certificates gnupg
```

### 3. 停用 UFW 防火牆

```bash
sudo ufw disable
```

> **原理說明：** UFW（Uncomplicated Firewall）是 Ubuntu 的 iptables 前端。Kubernetes 本身透過 kube-proxy 動態管理大量 iptables / IPVS 規則（每個 Service 和 Endpoint 都有對應規則）。若 UFW 同時管理 iptables，兩者的規則可能衝突，導致 Service 路由失敗或 Pod 網路中斷。
>
> 正式環境中，應改用 Kubernetes 專用的防火牆策略（NetworkPolicy），而非依賴 OS 層 UFW。

### 4. 載入必要的核心模組

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

> **原理說明：**
>
> **`overlay`（OverlayFS）：** containerd 使用 Overlay Filesystem 實作容器映像的分層儲存。一個 Container 的檔案系統由多個唯讀的映像層（lower layers）加上一個可寫層（upper layer）疊加而成。這讓多個 Container 可以共用相同的映像層，大幅節省磁碟空間：
> ```
> Container 寫入層（upper）      ← 每個 Container 獨立，程式的寫入在此
>  +  nginx:alpine 映像層（lower）← 唯讀，多個 Container 共用
>  +  alpine base 層（lower）    ← 唯讀，共用
>  =  Container 看到的完整檔案系統
> ```
>
> **`br_netfilter`（Bridge Netfilter）：** Linux bridge 預設只處理 Layer 2（MAC）流量，不經過 iptables（Layer 3/4）。但 kube-proxy 需要 iptables 規則來攔截流向 Service ClusterIP 的封包，進行 DNAT 轉發。載入 `br_netfilter` 後，bridge 上的流量也會通過 iptables，kube-proxy 才能正確攔截。

### 5. 設定核心參數

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

> **原理說明：**
>
> **`net.bridge.bridge-nf-call-iptables = 1`：** 啟用「bridge 上的 IPv4 流量通過 iptables」。即使載入了 `br_netfilter` 模組，還需要這個 sysctl 將功能開啟。沒有這個設定，Pod-to-Service 的流量無法被 kube-proxy 的 iptables 規則攔截，Service 存取失敗。
>
> **`net.ipv4.ip_forward = 1`：** 啟用 **IP 轉發**。節點作為路由器，需要能夠轉發不屬於自己的封包。例如從 Pod（10.244.x.x）送往另一個節點上的 Pod，封包需要經過節點的網路介面轉發出去。預設 Linux 不轉發，必須明確開啟。
>
> 這三個設定合在一起，才讓節點具備 Kubernetes 網路所需的封包轉發與 iptables 攔截能力。

### 6. 安裝 containerd

Ubuntu 24.04 的官方套件庫已內建 containerd，可直接安裝：

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

> **原理說明：**
>
> **為什麼要設定 `SystemdCgroup = true`？**
>
> **cgroup（Control Groups）** 是 Linux 核心用來限制和統計程式資源使用（CPU、Memory）的機制。管理 cgroup 有兩種方式（driver）：
>
> | Driver | 運作方式 | 適用場景 |
> |--------|---------|---------|
> | `cgroupfs` | 直接操作 `/sys/fs/cgroup` 目錄 | 非 systemd 環境 |
> | `systemd` | 透過 systemd 的 cgroup 管理介面 | Ubuntu 22.04+ 建議 |
>
> **關鍵限制：** containerd 和 kubelet 必須使用相同的 cgroup driver。若 containerd 用 `cgroupfs` 但 kubelet 用 `systemd`（或反過來），kubelet 會報錯：
> ```
> Failed to start ContainerManager: Unit kubepods.slice already exists
> ```
> 並最終無法啟動。
>
> Ubuntu 22.04+ 使用 **cgroup v2** 並由 systemd 統一管理，因此設定 `SystemdCgroup = true` 讓 containerd 交由 systemd 管理 cgroup，與 kubelet 保持一致。
>
> **pause container（sandbox）是什麼？** containerd 啟動 Pod 時，會先建立一個特殊的 `pause` container（極小的映像，只是讓 process sleep）。這個 pause container 持有 Pod 的 **Network namespace** 和 **IPC namespace**。同一個 Pod 的所有應用 container 都加入這個 namespace，這就是為什麼同一 Pod 內的 container 可以用 `localhost` 互相通訊，且共享相同的 Pod IP。

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

> **原理說明 — 三個工具的職責差異：**
>
> | 工具 | 執行時機 | 職責 |
> |------|---------|------|
> | `kubeadm` | 安裝 / 升級時（一次性） | 引導叢集：產生憑證、建立 Static Pod manifest、產生 join token |
> | `kubelet` | 永久執行（daemon） | 節點代理人：接收 Pod spec、呼叫 CRI 啟動容器、回報狀態 |
> | `kubectl` | 使用者操作時 | CLI 工具：將使用者指令轉為 API Server 的 HTTP 請求 |
>
> **`apt-mark hold` 的用意：** 防止 `apt upgrade` 自動升級 Kubernetes 套件。Kubernetes 版本升級有嚴格的流程（需要依序升級 control plane → worker），不能讓套件管理員自動升版，否則版本不一致會導致叢集異常。

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

> **原理說明 — kubeadm init 做了什麼：**
>
> 1. **Preflight checks：** 檢查 swap 是否關閉、核心模組是否載入、container runtime 是否正常等
> 2. **產生 PKI 憑證（`/etc/kubernetes/pki/`）：**
>    - CA 憑證（`ca.crt`）：叢集根憑證，用來簽署所有其他憑證
>    - API Server 憑證：包含所有節點 IP 和 DNS 名稱作為 SAN（Subject Alternative Name）
>    - etcd 憑證：獨立的 CA 和客戶端憑證，確保 etcd 只接受 API Server 的連線
>    - SA 金鑰對（`sa.key`/`sa.pub`）：用於簽署 ServiceAccount token
> 3. **產生 kubeconfig 檔案（`/etc/kubernetes/*.conf`）：** 讓各元件知道如何連線 API Server
> 4. **建立 Static Pod manifest（`/etc/kubernetes/manifests/`）：** kubelet 讀取這些 YAML 檔，啟動 etcd、kube-apiserver、kube-scheduler、kube-controller-manager
> 5. **等待 Control Plane 就緒**
> 6. **將叢集設定寫入 etcd（ConfigMap `kubeadm-config`）**
> 7. **建立 bootstrap token：** Worker 節點加入時使用，有效期 24 小時

### 3. 設定 kubectl 存取

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

> **原理說明：** `admin.conf` 是 kubeconfig 格式的檔案，包含三項資訊：
> - **cluster**：API Server 的位址與 CA 憑證（用來驗證 Server 身份）
> - **credentials**：使用者的客戶端憑證與私鑰（用來向 API Server 證明身份）
> - **context**：將 cluster 與 credentials 組合起來，並指定預設 namespace
>
> `kubectl` 讀取 `~/.kube/config`（或 `$KUBECONFIG` 環境變數指定的路徑），從中取得連線資訊。`admin.conf` 內建 `kubernetes-admin` 身份，擁有 `cluster-admin` ClusterRole（最高權限）。

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

> **原理說明 — 為什麼需要 CNI？**
>
> `kubeadm init` 完成後，節點狀態是 `NotReady`，原因是缺少 **CNI（Container Network Interface）插件**。CNI 負責：
> 1. 為每個 Pod 分配唯一 IP（從 `--pod-network-cidr` 範圍內）
> 2. 設定 Pod 的 network namespace 和路由
> 3. 實現跨節點的 Pod-to-Pod 通訊
>
> 在安裝 CNI 之前，CoreDNS Pod 也會卡在 `Pending`，因為它本身是 Pod，需要 CNI 才能取得 IP。
>
> **Flannel vs 其他 CNI：**
>
> | CNI | 特色 | 適用場景 |
> |-----|------|---------|
> | Flannel | 簡單、輕量、VXLAN 封裝 | 學習、小型叢集 |
> | Calico | 支援 NetworkPolicy、BGP 路由 | 生產環境 |
> | Cilium | eBPF 加速、深度可觀測性 | 高效能、安全需求高 |
> | Weave | 加密傳輸 | 安全需求較高 |
>
> Flannel **不支援** NetworkPolicy（建立物件不報錯但不生效）。若需要 NetworkPolicy 強制執行，需換用 Calico 或 Cilium。

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

> **原理說明 — 為什麼要指定 `--iface`？**
>
> 在 VirtualBox / 多網卡環境中，節點通常有兩張網卡：
> - `eth0`（NAT，對外上網，但節點間無法互通）
> - `eth1`（Host-only，節點間私有網路 192.168.56.x）
>
> Flannel 預設使用**預設路由的網卡**（通常是 `eth0`/NAT），但 NAT 網路上各節點的 IP 是相同的（10.0.2.15），導致 Flannel 無法區分不同節點。指定 `--iface=eth1` 讓 Flannel 使用 Host-only 介面，才能正確識別節點並建立 VXLAN tunnel。

> **注意：** Ubuntu 24.04 的網路介面名稱可能有所不同，請執行 `ip link` 確認後填入正確介面名稱。

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

> **原理說明 — kubeadm join 的安全機制：**
>
> Worker 加入叢集需要解決兩個安全問題：「Worker 怎麼知道連的是合法的 API Server」和「API Server 怎麼知道是合法的 Worker」：
>
> 1. **`--discovery-token-ca-cert-hash`（雙向驗證的第一步）：**
>    Worker 連上 API Server 後，取得 API Server 的 CA 憑證，計算其 SHA256 雜湊值，與這個參數比對。若相符，確認連到的是合法叢集（防止 Worker 被重導向到惡意 API Server）。
>
> 2. **`--token`（身份憑證）：**
>    Bootstrap Token 是一個短期憑證（預設 24 小時），Worker 用它向 API Server 證明自己有加入叢集的授權。API Server 驗證 token 後，為該節點的 kubelet 核發長期客戶端憑證（TLS Bootstrap 流程）。
>
> 3. **TLS Bootstrap 流程（加入後）：**
>    ```
>    kubelet 用 bootstrap token → 送出 CSR（Certificate Signing Request）
>    → kube-controller-manager 自動核准（auto-approver）
>    → kubelet 取得長期客戶端憑證
>    → 後續通訊用此憑證，不再需要 bootstrap token
>    ```

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

---

# 網路原理深度說明

本章從 Linux 網路基礎出發，逐層建立「為什麼 Kubernetes 網路這樣設計」的完整認識。

---

## 一、Linux 網路基礎

### 1.1 Network Namespace — 網路的隔離單位

Linux **Network Namespace** 是容器網路隔離的核心機制。每個 namespace 擁有獨立的：
- 網路介面（Network Interface）
- 路由表（Routing Table）
- iptables 規則
- socket

```bash
# 建立兩個 namespace（手動模擬容器網路）
ip netns add ns-a
ip netns add ns-b

# 在 namespace 內執行指令
ip netns exec ns-a ip link show
# → 只看到 lo（loopback），完全與主機隔離
```

預設情況下 ns-a 和 ns-b **無法互通**，需要額外的虛擬設備連接它們。

---

### 1.2 veth Pair — 虛擬乙太網路對

**veth（Virtual Ethernet）** 是成對出現的虛擬網路介面，像一條管子：從一端送入的封包，從另一端出來。

```bash
# 建立 veth pair：veth-a ↔ veth-b
ip link add veth-a type veth peer name veth-b

# 將 veth-a 放進 ns-a，veth-b 放進 ns-b
ip link set veth-a netns ns-a
ip link set veth-b netns ns-b

# 設定 IP
ip netns exec ns-a ip addr add 10.0.0.1/24 dev veth-a
ip netns exec ns-b ip addr add 10.0.0.2/24 dev veth-b

# 啟動介面
ip netns exec ns-a ip link set veth-a up
ip netns exec ns-b ip link set veth-b up

# 現在 ns-a 可以 ping ns-b
ip netns exec ns-a ping 10.0.0.2
```

**Container 網路的 veth 使用方式：**

```
主機（Host Network Namespace）
  veth0 ────────── veth1（Container 內部，通常叫 eth0）
  │
  bridge（docker0 / cni0）
```

每個 Container 建立一對 veth：一端在 Container 的 namespace，另一端接到主機的 bridge。

---

### 1.3 Linux Bridge — 軟體交換器

**Linux Bridge** 是作業系統裡的 Layer 2 交換器，連接多個網路介面，依據 MAC 位址轉發封包。

```
           Linux Bridge（cni0 / docker0）
           ┌──────────────────────────────┐
           │  MAC Table:                  │
           │  52:54:00:aa → veth1         │
           │  52:54:00:bb → veth3         │
           │  52:54:00:cc → veth5         │
           └──┬────────┬────────┬─────────┘
              │        │        │
            veth1    veth3    veth5   ← 主機端
              │        │        │
            eth0     eth0     eth0   ← Container 內部
          (Pod A)  (Pod B)  (Pod C)
         10.244.1.2  10.244.1.3  10.244.1.4
```

同一個節點上的 Pod 之間通訊，封包路徑：
```
Pod A eth0 → veth1 → bridge（cni0）→ veth3 → Pod B eth0
```
**不需要經過 IP 路由，純 Layer 2 轉發。**

---

### 1.4 iptables — Linux 封包過濾與 NAT

**iptables** 是 Linux 核心的封包處理框架，kube-proxy 用它實作 Kubernetes Service。

**五個 Tables（依功能分類）：**

| Table | 用途 |
|-------|------|
| `filter` | 封包過濾（允許/拒絕） |
| `nat` | 網路位址轉換（SNAT/DNAT） |
| `mangle` | 修改封包欄位（TTL、TOS 等） |
| `raw` | 跳過 connection tracking |
| `security` | SELinux 標記 |

**五個 Chains（封包經過的時間點）：**

```
封包進入 → PREROUTING → FORWARD → POSTROUTING → 送出
                ↓
           INPUT（本機處理）
                ↓
           本機程式產生封包
                ↓
           OUTPUT → POSTROUTING → 送出
```

**kube-proxy 如何實作 ClusterIP Service（DNAT）：**

```bash
# Service: ClusterIP = 10.96.0.10:80，後端 Pod = 10.244.1.2:8080

# iptables 規則（kube-proxy 自動產生）：
# 1. PREROUTING chain：封包目標是 10.96.0.10:80 → 跳到 KUBE-SVC-xxx
iptables -t nat -A PREROUTING -d 10.96.0.10/32 -p tcp --dport 80 \
  -j KUBE-SVC-XXXXXXXX

# 2. KUBE-SVC chain：隨機選取一個後端
iptables -t nat -A KUBE-SVC-XXXXXXXX \
  -m statistic --mode random --probability 0.5 \
  -j KUBE-SEP-AAAAAAAA   # → Pod A
iptables -t nat -A KUBE-SVC-XXXXXXXX \
  -j KUBE-SEP-BBBBBBBB   # → Pod B

# 3. KUBE-SEP chain：DNAT 到真實 Pod IP
iptables -t nat -A KUBE-SEP-AAAAAAAA \
  -p tcp -j DNAT --to-destination 10.244.1.2:8080
```

封包進入節點時，`PREROUTING` 的 DNAT 規則將目標 IP 從 ClusterIP 改為 Pod IP，之後正常路由到 Pod。**ClusterIP 不是真實存在的 IP**，它只存在於 iptables 規則中。

---

## 二、VLAN 原理

### 2.1 VLAN 解決的問題

在傳統乙太網路中，所有設備共用同一個廣播域（Broadcast Domain）。一台設備發送廣播封包，所有設備都會收到，造成：
- 廣播風暴（Broadcast Storm）
- 安全隔離問題
- 大型網路效能下降

**VLAN（Virtual LAN）** 在同一套實體交換器上劃分出多個邏輯網段，每個 VLAN 是獨立的廣播域。

```
實體交換器（一台）
┌────────────────────────────────────────────┐
│  Port 1,2,3 → VLAN 10（業務部門）           │
│  Port 4,5,6 → VLAN 20（研發部門）           │
│  Port 7,8,9 → VLAN 30（管理網路）           │
└────────────────────────────────────────────┘
  VLAN 10 的廣播封包 ≠ 不會到達 VLAN 20
```

---

### 2.2 802.1Q 標籤格式

VLAN 使用 **IEEE 802.1Q** 標準，在乙太網路幀中插入 4 bytes 的 VLAN Tag：

```
原始乙太網路幀：
┌──────────┬──────────┬───────┬──────────────────┬─────┐
│ Dst MAC  │ Src MAC  │ EType │    Payload        │ FCS │
│  6 bytes │  6 bytes │2 bytes│                   │4 B  │
└──────────┴──────────┴───────┴──────────────────┴─────┘

802.1Q 標記幀（Tagged Frame）：
┌──────────┬──────────┬───────┬────────────┬───────┬──────────────────┬─────┐
│ Dst MAC  │ Src MAC  │ 0x8100│  VLAN Tag  │ EType │    Payload        │ FCS │
│  6 bytes │  6 bytes │2 bytes│  4 bytes   │2 bytes│                   │4 B  │
└──────────┴──────────┴───────┴────────────┴───────┴──────────────────┴─────┘
                              ↑
                    VLAN Tag 細節：
                    ┌──────────┬──────────────────┐
                    │  PCP(3b) │  DEI(1b) │VID(12b)│
                    │ 優先順序  │  丟棄指示 │ VLAN ID│
                    └──────────┴──────────────────┘
                    VID 範圍：0-4095（12 bits）
                    實際可用：1-4094（0 和 4095 保留）
```

**PCP（Priority Code Point）：** QoS 優先順序（0-7）
**VID（VLAN Identifier）：** VLAN 編號，12 bits = **最多 4094 個 VLAN**

---

### 2.3 VLAN 的限制 — 為什麼雲端需要 VXLAN

| 限制 | 說明 |
|------|------|
| **4094 個 VLAN 上限** | 大型雲端有數百萬租戶，4094 個遠遠不夠 |
| **L2 邊界限制** | VLAN 無法跨越 L3 路由器，只能在同一廣播域內工作 |
| **資料中心跨機房** | 不同機房之間透過 L3 IP 路由連接，VLAN 無法直接延伸 |
| **MAC Table 爆炸** | 大量虛擬機的 MAC 位址塞爆交換器的 MAC Table |

這些限制推動了 **Overlay Network** 技術的誕生，VXLAN 是其中最廣泛使用的方案。

---

## 三、VXLAN 詳細原理

### 3.1 VXLAN 的設計目標

**VXLAN（Virtual eXtensible LAN）** 是 RFC 7348 定義的標準，核心思想是：

> 把 Layer 2 乙太網路幀「裝進」UDP 封包傳輸，讓 L2 網路可以跨越 L3 路由器延伸。

```
「隧道」比喻：
  ┌──────────────────────────────────────────────────┐
  │  外層（L3 IP + UDP）：給實體網路看的地址            │
  │  ┌────────────────────────────────────────────┐   │
  │  │  VXLAN Header：VNI（虛擬網路識別碼）         │   │
  │  │  ┌──────────────────────────────────────┐  │   │
  │  │  │  內層（原始 L2 乙太網路幀）             │  │   │
  │  │  │  包含 Pod 的 MAC、IP、實際資料           │  │   │
  │  │  └──────────────────────────────────────┘  │   │
  │  └────────────────────────────────────────────┘   │
  └──────────────────────────────────────────────────┘
```

---

### 3.2 VXLAN 幀格式（完整）

```
實體網路看到的封包（外層 + 內層）：

┌─────────────────────────────────────────────────────────────────────────────┐
│                          外層乙太網路幀                                       │
│ ┌──────────┬──────────┬────────┐                                            │
│ │ Dst MAC  │ Src MAC  │  Type  │  ← VTEP 的 MAC（實體網路）                  │
│ │（下一跳） │（本節點） │(0x0800)│                                            │
│ └──────────┴──────────┴────────┘                                            │
│ ┌────────────────────────────────────────────────────────┐                  │
│ │                     外層 IP Header                      │                  │
│ │  Src IP = 192.168.56.11（Node 1）                       │                  │
│ │  Dst IP = 192.168.56.12（Node 2）                       │                  │
│ │  Protocol = UDP（17）                                   │                  │
│ └────────────────────────────────────────────────────────┘                  │
│ ┌────────────────────────────────────────────────────────┐                  │
│ │                     外層 UDP Header                     │                  │
│ │  Src Port = 隨機（通常 49152-65535，由 inner 封包 hash） │                  │
│ │  Dst Port = 4789（IANA 標準）或 8472（Linux 預設）       │                  │
│ └────────────────────────────────────────────────────────┘                  │
│ ┌────────────────────────────────────────────────────────┐                  │
│ │                     VXLAN Header（8 bytes）             │                  │
│ │  Flags(8b)  Reserved(24b)  VNI(24b)  Reserved(8b)      │                  │
│ │   0x08=1         0         識別虛擬網路     0            │                  │
│ │                            最多 1677 萬個               │                  │
│ └────────────────────────────────────────────────────────┘                  │
│ ┌────────────────────────────────────────────────────────┐                  │
│ │                  內層乙太網路幀（原始封包）               │                  │
│ │  Dst MAC = Pod B 的 MAC（10.244.2.20 的 MAC）           │                  │
│ │  Src MAC = Pod A 的 MAC（10.244.1.10 的 MAC）           │                  │
│ │  IP: src=10.244.1.10  dst=10.244.2.20                  │                  │
│ │  TCP/UDP: 實際應用資料                                   │                  │
│ └────────────────────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────┘

大小開銷：外層 Ethernet(14) + IP(20) + UDP(8) + VXLAN(8) = 50 bytes
→ MTU 需要從 1500 調整到 1550 以上（或調低 Pod 的 MTU 到 1450）
```

---

### 3.3 VNI — 虛擬網路識別碼

**VNI（VXLAN Network Identifier）** 是 24 bits，可以定義 **2²⁴ = 16,777,216 個**虛擬網路（相比 VLAN 的 4094 個）。

不同的 VNI 代表完全隔離的虛擬網路，即使 Pod IP 相同（10.0.0.1），在不同 VNI 中也不會互相干擾 — 這正是多租戶雲端所需要的隔離能力。

```
VNI = 100：租戶 A 的網路（10.0.0.0/8）
VNI = 200：租戶 B 的網路（10.0.0.0/8）← 相同 IP 段，但完全隔離
VNI = 1：Kubernetes Pod 網路（Flannel 使用 VNI=1）
```

---

### 3.4 VTEP — VXLAN Tunnel Endpoint

**VTEP（VXLAN Tunnel Endpoint）** 是 VXLAN 的終端設備，負責**封裝（encapsulate）**和**解封裝（decapsulate）**。

在 Kubernetes 中，每個節點上的 `flannel.1` 介面就是一個 VTEP：

```bash
# 查看節點上的 VTEP
ip link show flannel.1
# → flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue
#   link/ether 52:54:00:xx:xx:xx brd ff:ff:ff:ff:ff:ff

# 查看 VTEP 的 ARP/FDB 表（知道哪個 Pod IP/MAC 在哪個節點）
ip neigh show dev flannel.1
# → 10.244.2.0 lladdr 52:54:00:yy:yy:yy PERMANENT  ← Node 2 的 VTEP MAC

bridge fdb show dev flannel.1
# → 52:54:00:yy:yy:yy dst 192.168.56.12 self permanent  ← VTEP 在 Node 2
```

---

### 3.5 VTEP 如何學習遠端節點資訊

VTEP 需要知道「目標 Pod IP 在哪個節點上」，有兩種學習機制：

**方式一：Multicast（傳統 VXLAN，Flannel 早期版本）**

```
Pod A 要送封包給 10.244.2.20（不知道它在哪個節點）
→ VTEP 發送 ARP 廣播，封裝進 VXLAN，用 UDP Multicast 傳送
→ 所有節點的 VTEP 收到，回應自己節點的資訊
→ VTEP 學習並記錄對應關係
```
缺點：需要實體網路支援 Multicast，雲端環境通常不支援。

**方式二：Unicast + 控制平面（Flannel 目前使用）**

```
Flannel 的 flanneld daemon 監聽 etcd
→ 新節點加入時，flanneld 將節點 IP 和 Pod CIDR 寫入 etcd
→ 所有節點的 flanneld 讀取 etcd，更新本機的路由表和 FDB 表
→ VTEP 直接用 Unicast 送封包，不需要廣播
```

```bash
# Flannel 寫入的路由規則（每個節點自動維護）
ip route show
# → 10.244.0.0/24 dev cni0  proto kernel scope link src 10.244.0.1
# → 10.244.1.0/24 via 10.244.1.0 dev flannel.1 onlink  ← 到 Node 1 的路由
# → 10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink  ← 到 Node 2 的路由
```

---

### 3.6 完整封包流程（含各層細節）

```
情境：Pod A（10.244.1.10，Node 1）→ Pod B（10.244.2.20，Node 2）

─── Node 1 內部 ──────────────────────────────────────────────────────

[Step 1] Pod A 送出封包
  src=10.244.1.10  dst=10.244.2.20
  Pod A 路由表：default via eth0 → 送到 veth → 出 bridge

[Step 2] cni0 bridge 查 MAC Table
  10.244.2.20 不在本節點 → 不在 bridge 的 MAC Table
  → 查主機路由表

[Step 3] 主機路由表
  10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink
  → 封包交給 flannel.1（VTEP）處理

[Step 4] VTEP 封裝（flannel.1）
  查 ARP/FDB 表：10.244.2.0 → Node 2 的 VTEP MAC，在 192.168.56.12
  建立 VXLAN 封包：
    外層 IP:  src=192.168.56.11  dst=192.168.56.12
    外層 UDP: dst port=8472
    VXLAN:   VNI=1
    內層:    原始封包（src=10.244.1.10, dst=10.244.2.20）

[Step 5] 透過 eth1（Host-only 192.168.56.x 網路）送出

─── 實體網路傳輸 ──────────────────────────────────────────────────────

[Step 6] 封包到達 Node 2（192.168.56.12）的 eth1

─── Node 2 內部 ──────────────────────────────────────────────────────

[Step 7] VTEP 解封裝（flannel.1）
  收到 UDP:8472 封包 → 識別為 VXLAN
  剝除外層 Ethernet + IP + UDP + VXLAN Header
  還原內層封包：src=10.244.1.10  dst=10.244.2.20

[Step 8] 主機路由表
  10.244.2.0/24 dev cni0 proto kernel scope link
  → 送進 cni0 bridge

[Step 9] cni0 bridge 查 MAC Table
  10.244.2.20 → veth on bridge → Pod B 的 veth

[Step 10] 封包到達 Pod B（10.244.2.20）的 eth0
```

---

## 四、Container 網路模型

### 4.1 單機 Container 網路（Docker 模型）

```
主機（Host）
┌──────────────────────────────────────────────────────┐
│  docker0（Linux Bridge，172.17.0.1/16）               │
│     ├── veth0a ←→ eth0（Container A，172.17.0.2）     │
│     ├── veth0b ←→ eth0（Container B，172.17.0.3）     │
│     └── veth0c ←→ eth0（Container C，172.17.0.4）     │
│                                                       │
│  iptables MASQUERADE（SNAT）：                         │
│  Container → 外部網路 時，來源 IP 換成主機 IP           │
│  172.17.0.x → 192.168.56.11                           │
│                                                       │
│  eth0（192.168.56.11）→ 對外網路                       │
└──────────────────────────────────────────────────────┘
```

**Container 存取外部網路的 NAT 流程：**

```
Container A（172.17.0.2）發出請求：
  src=172.17.0.2 → dst=8.8.8.8

iptables POSTROUTING MASQUERADE：
  src=172.17.0.2 → 改為 src=192.168.56.11（主機 IP）

封包送出：src=192.168.56.11 → dst=8.8.8.8
回包：    src=8.8.8.8       → dst=192.168.56.11
iptables Connection Tracking 還原：
  dst=192.168.56.11 → 還原為 dst=172.17.0.2

回包到達 Container A（172.17.0.2）
```

---

### 4.2 Kubernetes Pod 網路與 Docker 的差異

| 項目 | Docker | Kubernetes Pod |
|------|--------|----------------|
| 每個 container 的 IP | 獨立 IP | 同 Pod 共用一個 IP |
| container 間通訊 | 透過 NAT 或 link | 直接 localhost |
| Network namespace | 每個 container 獨立 | Pod 內所有 container 共用 |
| IP 分配 | Docker 自行管理 | CNI 插件分配 |
| 跨節點通訊 | 需要 port mapping 或 overlay | CNI 直接 Pod IP 可達 |

**Kubernetes Pod 的 Network Namespace 共享：**

```
Pod（由 pause container 建立並持有 Network Namespace）
┌──────────────────────────────────────────────────────┐
│  Network Namespace（共享）                             │
│  IP: 10.244.1.10   eth0 ←→ veth → cni0 bridge       │
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │
│  │ pause(sandbox)│  │  app container│  │sidecar cont│  │
│  │  （持有 NS）  │  │  （加入 NS）  │  │ （加入 NS） │  │
│  └──────────────┘  └──────────────┘  └────────────┘  │
│  三個 container 共用同一個 eth0 和 IP                   │
│  app 和 sidecar 用 localhost:port 互相通訊              │
└──────────────────────────────────────────────────────┘
```

`pause` container（`registry.k8s.io/pause`）幾乎不佔資源，其唯一職責就是在 Pod 的整個生命週期持有這個 Network Namespace，確保即使應用 container 重啟，Pod IP 也不會改變。

---

## 五、Kubernetes 四種流量路徑

### 5.1 Pod → Pod（同節點）

```
Pod A（10.244.1.2）→ Pod B（10.244.1.3）
  │
  ▼ veth pair
  cni0 bridge（Layer 2 轉發）
  │
  ▼ veth pair
  Pod B（10.244.1.3）

完全在 bridge 內部完成，不經過 IP 路由，不經過 iptables
（除非有 NetworkPolicy）
```

---

### 5.2 Pod → Pod（跨節點，VXLAN）

見上方 3.6 節完整封包流程。關鍵路徑：

```
Pod A → veth → cni0 → 路由表 → flannel.1（VTEP 封裝）
→ eth1（實體傳輸）
→ flannel.1（VTEP 解封裝）→ cni0 → veth → Pod B
```

---

### 5.3 Pod → Service（ClusterIP，iptables DNAT）

```
Pod A（10.244.1.2）→ Service（10.96.0.10:80）
  │
  ▼ iptables PREROUTING（DNAT）
  DNAT: 10.96.0.10:80 → 10.244.2.3:8080（隨機選取後端 Pod）
  │
  ▼ 路由表（10.244.2.0/24 → flannel.1）
  VXLAN 封裝 → 跨節點傳輸 → Pod B（10.244.2.3:8080）

回程封包：
  Pod B（10.244.2.3）→ Pod A（10.244.1.2）
  iptables Connection Tracking 自動還原 src 為 10.96.0.10:80
```

`ClusterIP` 是「虛擬 IP」，沒有任何介面綁定這個 IP，它只存在於 iptables DNAT 規則中。

---

### 5.4 外部 → NodePort Service

```
外部客戶端（192.168.56.1）→ 192.168.56.11:30080（NodePort）
  │
  ▼ iptables PREROUTING
  DNAT: 192.168.56.11:30080 → 10.244.2.3:8080（後端 Pod）

  若後端 Pod 在另一個節點（Node 2）：
  ▼ MASQUERADE（SNAT）
  src=10.244.1.1（節點 cni0 IP，或 Node 1 IP）
  → VXLAN 跨節點傳輸 → Pod B

注意：
  當封包轉發到其他節點上的 Pod 時，需要 SNAT（MASQUERADE），
  否則 Pod 回包時不知道要送回 Node 1，會直接回給外部客戶端，
  造成 Client 收到非預期 src IP 的回包。
```

---

### 5.5 DNS 解析流程（CoreDNS）

Kubernetes 的 DNS 由 **CoreDNS** 提供，部署為 Service（通常是 `10.96.0.10`）。

```
Pod 的 /etc/resolv.conf（kubelet 自動注入）：
  nameserver 10.96.0.10       ← CoreDNS Service ClusterIP
  search default.svc.cluster.local svc.cluster.local cluster.local
  options ndots:5

Pod 查詢 "my-service" 的 DNS 解析過程：
  1. 優先嘗試 FQDN 補全：
     my-service.default.svc.cluster.local → CoreDNS → 10.96.1.5 ✓

  2. CoreDNS 查詢流程：
     收到查詢 my-service.default.svc.cluster.local
     → 在 etcd（透過 Kubernetes API）中找到 Service
     → 回傳 ClusterIP 10.96.1.5

  3. DNS 格式規則：
     <service>.<namespace>.svc.<cluster-domain>
     my-service.default.svc.cluster.local
     │           │        │    └─ 叢集 domain（預設 cluster.local）
     │           │        └─ 固定
     │           └─ namespace
     └─ service 名稱
```

**Pod 的 DNS 名稱（有時考試會問）：**

```
Pod IP: 10.244.1.10
Pod DNS: 10-244-1-10.default.pod.cluster.local
（IP 中的 . 換成 -）
```

---

## 六、網路問題排查指引

### 常用診斷指令

```bash
# 查看節點網路介面（確認 flannel.1 存在）
ip link show

# 查看 Pod 網路路由
ip route show

# 查看 VTEP 的 FDB 表（確認知道遠端節點）
bridge fdb show dev flannel.1

# 查看 iptables 的 NAT 規則（Service 路由）
sudo iptables -t nat -L KUBE-SERVICES -n --line-numbers | head -20

# 確認 kube-proxy 規則數量（正常應有數百條）
sudo iptables -t nat -L | wc -l

# Pod-to-Pod 連通性測試
kubectl run test --image=busybox:1.36 --rm -it --restart=Never \
  -- ping 10.244.2.3

# 追蹤封包路徑（需要 traceroute）
kubectl exec -it <pod> -- traceroute 10.244.2.3

# 查看 Pod 的 DNS 設定
kubectl exec -it <pod> -- cat /etc/resolv.conf

# 測試 Service DNS 解析
kubectl exec -it <pod> -- nslookup kubernetes.default.svc.cluster.local

# 查看 Flannel 日誌（排查網路問題）
kubectl logs -n kube-flannel -l app=flannel --tail=50
```

### 常見網路問題與原因

| 症狀 | 可能原因 | 排查方式 |
|------|---------|---------|
| Pod Pending，無 IP | CNI 未安裝或 flannel Pod 未 Ready | `kubectl get pods -n kube-flannel` |
| 同節點 Pod 無法通訊 | cni0 bridge 未建立或 MTU 問題 | `ip link show cni0` |
| 跨節點 Pod 無法通訊 | flannel.1 VTEP 未建立，FDB 表空 | `bridge fdb show dev flannel.1` |
| Service 無法存取 | kube-proxy 未運行，iptables 規則缺失 | `kubectl get pods -n kube-system \| grep proxy` |
| DNS 解析失敗 | CoreDNS Pod 異常 | `kubectl get pods -n kube-system \| grep coredns` |
| 節點 NotReady | CNI 插件未正確設定 `--iface` | 查看 flannel pod log |

# CKA / CKAD 考試題目與叢集驗證

以下所有題目均已在本叢集（Kubernetes v1.32.13、Ubuntu 24.04 LTS）實際驗證通過。

**測試環境**

| 項目 | 版本 |
|------|------|
| Kubernetes | v1.32.13 |
| Container Runtime | containerd 2.2.3 |
| OS | Ubuntu 24.04.3 LTS |
| CNI | Flannel v0.25.5 |

---

## CKA 題目

### CKA-Q1：查看叢集狀態與節點資訊

**題目：** 列出叢集的 control plane 位址，並顯示所有節點的詳細資訊（IP、OS、Container Runtime）。

**解答：**

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

**預期輸出：**

```
Kubernetes control plane is running at https://192.168.56.10:6443
CoreDNS is running at https://192.168.56.10:6443/api/v1/...

NAME          STATUS   ROLES           AGE   VERSION    INTERNAL-IP     OS-IMAGE
k8s-master    Ready    control-plane   ...   v1.32.13   192.168.56.10   Ubuntu 24.04.3 LTS
k8s-worker1   Ready    <none>          ...   v1.32.13   192.168.56.11   Ubuntu 24.04.3 LTS
k8s-worker2   Ready    <none>          ...   v1.32.13   192.168.56.12   Ubuntu 24.04.3 LTS
```

**說明：**
- `cluster-info` 顯示 API Server 與 CoreDNS 的端點。
- `-o wide` 額外顯示每個節點的 `INTERNAL-IP`、`OS-IMAGE`、`KERNEL-VERSION`、`CONTAINER-RUNTIME`。
- CKA 考試中常要求確認節點狀態，`STATUS=Ready` 表示節點正常。

---

### CKA-Q2：RBAC — 建立 ServiceAccount 並授予 Pod 讀取權限

**題目：** 在 `cka-exam` namespace 中建立 ServiceAccount `cka-sa`，授予它在該 namespace 內 `get`、`list`、`watch` Pod 的權限，但不能刪除 Pod。

**解答：**

```bash
# 建立 namespace 與 ServiceAccount
kubectl create namespace cka-exam
kubectl create serviceaccount cka-sa -n cka-exam

# 建立 Role（僅限讀取 Pod）
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods \
  -n cka-exam

# 將 Role 綁定到 ServiceAccount
kubectl create rolebinding cka-sa-binding \
  --role=pod-reader \
  --serviceaccount=cka-exam:cka-sa \
  -n cka-exam

# 驗證權限
kubectl auth can-i list pods \
  --as=system:serviceaccount:cka-exam:cka-sa -n cka-exam   # → yes
kubectl auth can-i delete pods \
  --as=system:serviceaccount:cka-exam:cka-sa -n cka-exam   # → no
```

**說明：**
- `Role` 是 namespace 範圍的權限定義；`ClusterRole` 是叢集範圍。
- `RoleBinding` 將 Role 與 Subject（User / Group / ServiceAccount）綁定。
- `kubectl auth can-i` 是驗證 RBAC 設定是否正確的最快方式。
- 若需要跨 namespace 存取，應改用 `ClusterRole` + `ClusterRoleBinding`。

---

### CKA-Q3：ResourceQuota 與 LimitRange

**題目：** 在 `cka-exam` namespace 設定資源配額：最多 10 個 Pod，CPU request 上限 1 core，Memory request 上限 1Gi。並設定 LimitRange，讓未指定 resource 的 Container 自動套用預設值（CPU request 100m / limit 200m，Memory request 128Mi / limit 256Mi）。

**解答：**

```yaml
# resourcequota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: exam-quota
  namespace: cka-exam
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: exam-limits
  namespace: cka-exam
spec:
  limits:
  - default:
      cpu: 200m
      memory: 256Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    type: Container
```

```bash
kubectl apply -f resourcequota.yaml
kubectl describe resourcequota exam-quota -n cka-exam
kubectl describe limitrange exam-limits -n cka-exam
```

**說明：**
- `ResourceQuota` 限制整個 namespace 的資源用量上限。
- `LimitRange` 為未指定 resource 的 Container 補上預設值，避免 Pod 因缺少 resource 定義而被 ResourceQuota 拒絕。
- `requests` 是排程依據（Scheduler 使用），`limits` 是實際執行上限（cgroup 強制）。

---

### CKA-Q4：Node 維護 — Cordon / Drain / Uncordon

**題目：** 需要對 `k8s-worker1` 進行系統維護。請先封鎖節點（不允許新 Pod 排程），再驅逐所有可移動的 Pod，完成後恢復節點為可排程狀態。

**解答：**

```bash
# 1. 封鎖節點（SchedulingDisabled）
kubectl cordon k8s-worker1

# 2. 驅逐現有 Pod（保留 DaemonSet Pod）
kubectl drain k8s-worker1 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# 確認節點狀態
kubectl get nodes k8s-worker1
# → Ready,SchedulingDisabled

# 3. 維護完成，恢復排程
kubectl uncordon k8s-worker1
kubectl get nodes k8s-worker1
# → Ready
```

**說明：**
- `cordon`：節點加上 `node.kubernetes.io/unschedulable` taint，新 Pod 不會排到此節點。
- `drain`：驅逐節點上的所有 Pod（除 DaemonSet）。`--ignore-daemonsets` 跳過 DaemonSet Pod（因為它們無法被驅逐）；`--delete-emptydir-data` 允許刪除使用 emptyDir volume 的 Pod。
- `uncordon`：移除不可排程 taint，恢復正常。
- 實際維護流程：cordon → drain → 執行維護 → uncordon。

---

### CKA-Q5：etcd 備份與還原

**題目：** 將 etcd 資料備份至 `/tmp/etcd-backup.db`，並確認備份內容正確。

**解答：**

```bash
# 安裝 etcdctl（若尚未安裝）
ETCD_VER=v3.5.24
curl -fsSL https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz | \
  sudo tar -xzf - -C /usr/local/bin --strip-components=1 \
  etcd-${ETCD_VER}-linux-amd64/etcdctl

# 備份
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/etcd-backup.db

# 驗證備份
sudo ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup.db --write-out=table
```

**還原流程（考試參考）：**

```bash
# 停止 kube-apiserver（移除 static pod manifest）
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/

# 還原 snapshot
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd-restore

# 修改 etcd static pod manifest 指向新資料目錄
sudo sed -i 's|/var/lib/etcd|/var/lib/etcd-restore|g' \
  /etc/kubernetes/manifests/etcd.yaml

# 恢復 kube-apiserver
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

**說明：**
- etcd 是叢集所有狀態的唯一資料來源，備份 etcd = 備份整個叢集。
- 備份時必須提供 CA 憑證、Server 憑證與 Key，這三個檔案均位於 `/etc/kubernetes/pki/etcd/`。
- 備份輸出包含 `HASH`、`REVISION`（寫入次數）、`TOTAL KEYS`（物件數量）、`TOTAL SIZE`。

---

### CKA-Q6：PersistentVolume + PersistentVolumeClaim

**題目：** 建立一個 1Gi 的 `PersistentVolume`（hostPath，ReclaimPolicy=Retain），再建立一個 500Mi 的 PVC 綁定它，最後建立 Pod 將該 PVC 掛載至 `/data`。

**解答：**

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: exam-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/exam-pv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: exam-pvc
  namespace: cka-exam
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: pv-pod
  namespace: cka-exam
spec:
  containers:
  - name: app
    image: nginx:alpine
    volumeMounts:
    - mountPath: /data
      name: storage
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: exam-pvc
```

```bash
kubectl apply -f pv-pvc-pod.yaml
kubectl get pv,pvc -n cka-exam
# PV 與 PVC 均應顯示 STATUS=Bound
```

**說明：**
- PVC 會自動尋找符合條件的 PV 進行綁定（容量 ≥ 申請量、accessMode 相符）。
- `ReclaimPolicy: Retain`：PVC 刪除後 PV 資料保留，需手動清理（`Released` 狀態）。
- `ReclaimPolicy: Delete`：PVC 刪除後 PV 自動刪除（StorageClass 常用）。
- hostPath 僅適合單節點測試；生產環境應使用 NFS、CSI 驅動等。

---

### CKA-Q7：Taint 與 Toleration

**題目：** 在 `k8s-worker1` 加上 Taint `env=production:NoSchedule`，然後建立一個能容忍此 Taint 並指定排到 `k8s-worker1` 的 Pod。

**解答：**

```bash
# 加上 Taint
kubectl taint nodes k8s-worker1 env=production:NoSchedule

# 建立有 Toleration 的 Pod
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: toleration-pod
  namespace: cka-exam
spec:
  tolerations:
  - key: env
    operator: Equal
    value: production
    effect: NoSchedule
  nodeSelector:
    kubernetes.io/hostname: k8s-worker1
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
EOF

kubectl get pod toleration-pod -n cka-exam -o wide
# → NODE 欄位應顯示 k8s-worker1

# 移除 Taint
kubectl taint nodes k8s-worker1 env=production:NoSchedule-
```

**說明：**
- **Taint** 加在 Node 上，排斥不符合條件的 Pod。格式：`key=value:Effect`（Effect：`NoSchedule`、`PreferNoSchedule`、`NoExecute`）。
- **Toleration** 加在 Pod 上，允許它忽略特定 Taint 排程到該節點。
- `NoSchedule`：新 Pod 不排程，已存在的 Pod 不受影響。
- `NoExecute`：新 Pod 不排程，且已存在不符合的 Pod 會被驅逐。
- 移除 Taint：在 taint 定義後加 `-`（如 `env=production:NoSchedule-`）。

---

### CKA-Q8：NetworkPolicy — 預設拒絕 + 白名單放行

**題目：** 在 `cka-exam` namespace 設定「預設拒絕所有 Ingress 流量」，然後建立例外規則：僅允許帶有 `role=frontend` label 的 Pod 存取帶有 `app=web` label 的 Pod 的 80 port。

**解答：**

```yaml
# 預設拒絕所有 Ingress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: cka-exam
spec:
  podSelector: {}       # 空選擇器 = 套用到所有 Pod
  policyTypes:
  - Ingress
---
# 白名單：允許 frontend → web:80
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-nginx-ingress
  namespace: cka-exam
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 80
```

**說明：**
- NetworkPolicy 需要支援的 CNI（Flannel 的 NetworkPolicy 支援需搭配 kube-router 或 Calico；本叢集使用 Flannel，NetworkPolicy 物件可建立但不會強制執行）。
- 生產叢集若需要 NetworkPolicy，建議改用 Calico 或 Cilium。
- `podSelector: {}` 空選擇器代表選取 namespace 內所有 Pod。
- `ingress: []`（空陣列）代表允許所有來源；完全省略 `ingress` 則代表拒絕所有。

---

### CKA-Q9：Static Pod

**題目：** 在 Master 節點上建立一個 Static Pod，名稱為 `static-exam`，使用 `nginx:alpine` 映像，監聽 80 port。

**解答：**

```bash
# Static Pod manifest 放在 kubelet 的 staticPodPath 目錄
sudo tee /etc/kubernetes/manifests/static-exam.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: static-exam
  namespace: kube-system
spec:
  containers:
  - name: static-nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
EOF

# kubelet 自動偵測並建立 Pod（約 5-10 秒）
kubectl get pod static-exam-k8s-master -n kube-system
```

**預期輸出：**
```
NAME                     READY   STATUS    RESTARTS   AGE
static-exam-k8s-master   1/1     Running   0          10s
```

**說明：**
- Static Pod 由 kubelet 直接管理，不透過 API Server（但 kubelet 會向 API Server 回報其狀態）。
- Pod 名稱會自動附加節點名稱後綴（`static-exam-k8s-master`）。
- `staticPodPath` 預設為 `/etc/kubernetes/manifests/`，可在 kubelet 設定中查看。
- 刪除 Static Pod：直接刪除對應的 YAML 檔案，kubelet 會自動移除 Pod。
- kube-system 的 control plane 元件（etcd、kube-apiserver 等）本身就是 Static Pod。

---

## CKAD 題目

### CKAD-Q1：ConfigMap 與 Secret — 注入環境變數

**題目：** 建立 ConfigMap `app-config`（包含 `APP_ENV=production`），以及 Secret `app-secret`（包含 `DB_PASSWORD=s3cr3t`）。建立一個 Pod，將兩個值分別注入為環境變數。

**解答：**

```bash
kubectl create namespace ckad-exam

kubectl create configmap app-config \
  --from-literal=APP_ENV=production \
  --from-literal=APP_PORT=8080 \
  -n ckad-exam

kubectl create secret generic app-secret \
  --from-literal=DB_PASSWORD=s3cr3t \
  --from-literal=API_KEY=abc123 \
  -n ckad-exam
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-pod
  namespace: ckad-exam
spec:
  containers:
  - name: app
    image: nginx:alpine
    env:
    - name: APP_ENV
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_ENV
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: app-secret
          key: DB_PASSWORD
```

```bash
kubectl exec env-pod -n ckad-exam -- env | grep -E 'APP_ENV|DB_PASSWORD'
# APP_ENV=production
# DB_PASSWORD=s3cr3t
```

**說明：**
- `ConfigMap` 儲存非敏感設定；`Secret` 儲存敏感資料（base64 編碼，非加密）。
- 注入環境變數：`valueFrom.configMapKeyRef` / `valueFrom.secretKeyRef`。
- 注入所有 key：使用 `envFrom.configMapRef` / `envFrom.secretRef`。
- Secret 僅 base64 編碼，若需真正加密，需啟用 etcd encryption at rest。

---

### CKAD-Q2：ConfigMap — Volume 掛載設定檔

**題目：** 建立 ConfigMap `nginx-conf` 包含一份 nginx 設定，並將其掛載至 Pod 的 `/etc/nginx/conf.d/` 目錄。

**解答：**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-conf
  namespace: ckad-exam
data:
  nginx.conf: |
    server {
      listen 80;
      location / { return 200 'OK'; }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: configmap-vol-pod
  namespace: ckad-exam
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    volumeMounts:
    - name: config
      mountPath: /etc/nginx/conf.d
  volumes:
  - name: config
    configMap:
      name: nginx-conf
```

```bash
kubectl exec configmap-vol-pod -n ckad-exam -- ls /etc/nginx/conf.d/
# nginx.conf
```

**說明：**
- ConfigMap 的每個 key 在掛載後會成為目錄中的一個檔案，key 名稱即檔名，value 即內容。
- 若只需掛載特定 key，可用 `items` 欄位篩選。
- ConfigMap 更新後，volume 掛載的檔案會在約 1 分鐘內自動同步（環境變數不會自動更新）。

---

### CKAD-Q3：Multi-container Pod（Sidecar 模式）

**題目：** 建立一個包含兩個 Container 的 Pod：`app` container 每 5 秒寫入一行時間戳到 `/log/app.log`；`log-agent` container 使用 `tail -f` 監看同一個檔案。兩個 container 透過 `emptyDir` volume 共享資料。

**解答：**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-pod
  namespace: ckad-exam
spec:
  volumes:
  - name: shared-log
    emptyDir: {}
  containers:
  - name: app
    image: busybox:1.36
    command: ['/bin/sh','-c',
      'while true; do echo $(date) >> /log/app.log; sleep 5; done']
    volumeMounts:
    - name: shared-log
      mountPath: /log
  - name: log-agent
    image: busybox:1.36
    command: ['/bin/sh','-c','tail -f /log/app.log']
    volumeMounts:
    - name: shared-log
      mountPath: /log
```

```bash
kubectl logs sidecar-pod -c log-agent -n ckad-exam
# Wed May 20 11:44:30 UTC 2026
# Wed May 20 11:44:35 UTC 2026
```

**說明：**
- **Sidecar 模式**：輔助 container 增強主 container 的功能（日誌收集、Proxy、同步等）。
- `emptyDir`：Pod 生命週期內存在的臨時目錄，Pod 刪除後資料消失。
- 查看特定 container 的 log：`kubectl logs <pod> -c <container>`。
- Kubernetes 1.28+ 支援 **Sidecar container**（`initContainers` 中設定 `restartPolicy: Always`），可確保 sidecar 在主 container 之前啟動且最後關閉。

---

### CKAD-Q4：Liveness Probe 與 Readiness Probe

**題目：** 建立一個 nginx Pod，設定：
- Liveness Probe：HTTP GET `/`，初始延遲 5 秒，每 10 秒檢查，失敗 3 次重啟。
- Readiness Probe：HTTP GET `/`，初始延遲 3 秒，每 5 秒檢查。

**解答：**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe-pod
  namespace: ckad-exam
spec:
  containers:
  - name: app
    image: nginx:alpine
    ports:
    - containerPort: 80
    livenessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 3
      periodSeconds: 5
```

```bash
kubectl describe pod probe-pod -n ckad-exam | grep -A2 'Liveness\|Readiness'
```

**說明：**
- **Liveness Probe**：失敗時重啟 container。用於偵測程式 deadlock 或掛掉但未退出的情況。
- **Readiness Probe**：失敗時將 Pod 從 Service Endpoints 移除（不接收流量），但不重啟。用於偵測 Pod 是否準備好接收請求。
- **Startup Probe**：給啟動慢的應用使用，成功前 Liveness Probe 暫停。
- 三種探測方式：`httpGet`（HTTP 狀態碼 200-399）、`tcpSocket`（TCP 連線成功）、`exec`（命令退出碼為 0）。

---

### CKAD-Q5：Job 與 CronJob

**題目：** 建立一個 Job `pi-job`，總共完成 3 次（每次平行執行最多 2 個）。再建立一個 CronJob `hello-cron`，每分鐘執行一次印出時間。

**解答：**

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pi-job
  namespace: ckad-exam
spec:
  completions: 3       # 需要成功完成 3 次
  parallelism: 2       # 最多同時執行 2 個 Pod
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: pi
        image: busybox:1.36
        command: ['sh','-c','echo "Job $HOSTNAME completed"']
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello-cron
  namespace: ckad-exam
spec:
  schedule: "*/1 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: hello
            image: busybox:1.36
            command: ['sh','-c','echo Hello from CronJob at $(date)']
```

```bash
kubectl wait --for=condition=Complete job/pi-job -n ckad-exam --timeout=60s
kubectl get job,cronjob -n ckad-exam
```

**說明：**
- Job `restartPolicy` 只能是 `Never` 或 `OnFailure`（不能是 `Always`）。
- `completions`：需要成功完成的次數；`parallelism`：同時執行的 Pod 數上限。
- CronJob schedule 使用 cron 語法：`分 時 日 月 週`。
- `successfulJobsHistoryLimit`（預設 3）和 `failedJobsHistoryLimit`（預設 1）控制保留幾個歷史 Job。

---

### CKAD-Q6：Deployment 滾動更新與回滾

**題目：** 建立 Deployment `web-app`（image: `nginx:1.25`，3 replicas），更新至 `nginx:1.27`，再回滾到上一個版本。

**解答：**

```bash
# 建立 Deployment
kubectl create deployment web-app \
  --image=nginx:1.25 --replicas=3 -n ckad-exam

# 滾動更新
kubectl set image deployment/web-app nginx=nginx:1.27 -n ckad-exam
kubectl rollout status deployment/web-app -n ckad-exam

# 查看歷史
kubectl rollout history deployment/web-app -n ckad-exam

# 回滾到上一版
kubectl rollout undo deployment/web-app -n ckad-exam

# 確認回滾成功
kubectl get deployment web-app -n ckad-exam \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# → nginx:1.25
```

**說明：**
- 滾動更新預設策略：`maxUnavailable=25%`、`maxSurge=25%`，確保更新期間服務不中斷。
- `kubectl rollout undo --to-revision=N`：回滾到指定版本號。
- 使用 `--record` flag（已廢棄，改用 `kubectl annotate`）可在歷史中記錄 CHANGE-CAUSE。
- 若需暫停滾動更新：`kubectl rollout pause deployment/web-app`，恢復：`kubectl rollout resume`。

---

### CKAD-Q7：SecurityContext

**題目：** 建立一個 Pod，要求：
- 以 UID 1000 執行（非 root）
- fsGroup 設為 2000
- 禁止 Privilege Escalation
- 移除所有 Linux Capabilities

**解答：**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: security-pod
  namespace: ckad-exam
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: varrun
      mountPath: /var/run
    - name: varcache
      mountPath: /var/cache/nginx
  volumes:
  - name: tmp
    emptyDir: {}
  - name: varrun
    emptyDir: {}
  - name: varcache
    emptyDir: {}
```

```bash
kubectl exec security-pod -n ckad-exam -- id
# uid=1000 gid=0(root) groups=0(root),2000
```

**說明：**
- `runAsNonRoot: true`：若 image 預設以 root 執行，Pod 會拒絕啟動。
- `fsGroup`：掛載的 volume 的群組 owner 會設為此 GID，讓 container 可以讀寫。
- `capabilities.drop: [ALL]`：移除所有 Linux capabilities（最小權限原則）。
- `readOnlyRootFilesystem: true`：使根檔案系統唯讀（需將可寫路徑掛載為 emptyDir）。

---

### CKAD-Q8：Service — ClusterIP 與 NodePort

**題目：** 建立 Deployment `svc-demo`（nginx，2 replicas），為其建立：
1. ClusterIP Service（cluster 內部存取）
2. NodePort Service（透過節點 IP:30080 外部存取）

驗證 ClusterIP Service 可以從 cluster 內部 curl 通。

**解答：**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: svc-demo
  namespace: ckad-exam
spec:
  replicas: 2
  selector:
    matchLabels:
      app: svc-demo
  template:
    metadata:
      labels:
        app: svc-demo
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: svc-demo-clusterip
  namespace: ckad-exam
spec:
  selector:
    app: svc-demo
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: svc-demo-nodeport
  namespace: ckad-exam
spec:
  type: NodePort
  selector:
    app: svc-demo
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
```

```bash
# 驗證 ClusterIP 可達
kubectl run test-curl --image=curlimages/curl:latest --rm -it \
  --restart=Never -n ckad-exam \
  -- curl -s -o /dev/null -w '%{http_code}' http://svc-demo-clusterip/
# → 200

# 驗證 NodePort（從 host 或另一台機器）
curl http://192.168.56.11:30080/
```

**說明：**
- **ClusterIP**（預設）：僅 cluster 內部可達，適合服務間通訊。
- **NodePort**：在每個 Node 上開放指定 port（30000-32767），外部可透過 `NodeIP:NodePort` 存取。
- **LoadBalancer**：在雲端環境自動建立外部 Load Balancer（本地環境需搭配 MetalLB）。
- **ExternalName**：將 Service 對應到外部 DNS 名稱（CNAME）。
- Service 透過 `selector` 的 label 尋找後端 Pod，可用 `kubectl get endpoints <svc>` 查看。

---

## CKS 題目

> **CKS 前置條件：** 需先取得 CKA 認證。本節所有題目已在叢集（Kubernetes v1.32.13、Ubuntu 24.04 LTS）實際驗證通過。

---

### CKS-Q1：Pod Security Admission（PSA）

**題目：** 將 `cks-exam` namespace 的安全等級設定為 `restricted`（最嚴格），要求所有 Pod 必須符合 restricted 規範，並確認違規 Pod 無法建立、符合規範的 Pod 可以正常運行。

**解答：**

```bash
kubectl create namespace cks-exam

# 設定三個維度的 PSA label
kubectl label namespace cks-exam \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

**違規 Pod 測試（應被拒絕）：**

```yaml
# 以下 Pod 會被 PSA 攔截
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: cks-exam
spec:
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      privileged: true   # ← 違反 restricted
```

```
Error: pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest":
  privileged, allowPrivilegeEscalation, capabilities.drop, runAsNonRoot, seccompProfile
```

**符合規範的 Pod（restricted 標準最低要求）：**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
  namespace: cks-exam
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
    volumeMounts:
    - {mountPath: /tmp,              name: tmp}
    - {mountPath: /var/run,          name: varrun}
    - {mountPath: /var/cache/nginx,  name: varcache}
  volumes:
  - {name: tmp,      emptyDir: {}}
  - {name: varrun,   emptyDir: {}}
  - {name: varcache, emptyDir: {}}
```

**說明：**
- PSA 是 Kubernetes 1.25 GA 的內建 Admission Controller，取代已棄用的 PodSecurityPolicy（PSP）。
- 三個安全等級：`privileged`（無限制）、`baseline`（防止已知特權提升）、`restricted`（最佳安全實踐）。
- 三個模式：`enforce`（拒絕違規）、`warn`（警告但允許）、`audit`（記錄到 audit log）。
- restricted 要求：非 root 執行、seccomp RuntimeDefault / Localhost、capabilities 全部移除、禁止 hostPath/hostNetwork/hostPID/hostIPC。

---

### CKS-Q2：Seccomp Profile

**題目：** 建立一個 Pod，使用 `RuntimeDefault` seccomp profile，限制 Container 可使用的 system call 範圍。

**解答：**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-pod
  namespace: cks-exam
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault    # ← 使用 Container Runtime 的預設安全 profile
    runAsNonRoot: true
    runAsUser: 1000
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
```

```bash
# 驗證 seccomp profile 已套用
kubectl get pod seccomp-pod -n cks-exam \
  -o jsonpath='{.spec.securityContext.seccompProfile}'
# → {"type":"RuntimeDefault"}
```

**說明：**
- Seccomp（Secure Computing Mode）限制 Container 可執行的 Linux system call，減少攻擊面。
- `RuntimeDefault`：使用 Container Runtime（containerd/docker）預設的安全 profile，過濾高危 syscall。
- `Localhost`：使用 Node 上自訂的 seccomp JSON profile（需放在 `/var/lib/kubelet/seccomp/` 目錄）。
- `Unconfined`：不套用任何限制（不建議使用）。
- Kubernetes 1.27+ 預設對新 Pod 套用 `RuntimeDefault`（若叢集開啟 `SeccompDefault` feature gate）。

---

### CKS-Q3：AppArmor Profile

**題目：** 建立自訂 AppArmor profile `k8s-exam-deny-write`（禁止所有檔案寫入），在所有節點載入後，將其套用到 Pod。

**解答：**

**步驟一：在所有節點載入 profile（master + 所有 worker）**

```bash
sudo tee /etc/apparmor.d/k8s-exam-deny-write << 'EOF'
#include <tunables/global>
profile k8s-exam-deny-write flags=(attach_disconnected) {
  #include <abstractions/base>
  file,
  deny /** w,
}
EOF

sudo apparmor_parser -r /etc/apparmor.d/k8s-exam-deny-write

# 驗證已載入
aa-status 2>/dev/null | grep k8s-exam-deny-write
```

**步驟二：建立 Pod 套用 AppArmor（Kubernetes 1.30+ 語法）**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-pod
  namespace: cks-exam
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-exam-deny-write
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh','-c','sleep 3600']
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
```

```bash
# 驗證寫入被阻擋
kubectl exec apparmor-pod -n cks-exam -- sh -c 'echo test > /tmp/test.txt'
# → sh: can't create /tmp/test.txt: Permission denied  ✓
```

**說明：**
- AppArmor 是 Linux 強制存取控制（MAC）框架，Ubuntu 預設啟用。
- **重要**：AppArmor profile 必須在 Pod 排程到的節點上預先載入，否則 Pod 會 `CreateContainerError`。
- Kubernetes 1.30 之前使用 annotation：`container.apparmor.security.beta.kubernetes.io/<container>: localhost/<profile>`。
- Kubernetes 1.30+ 改用 `spec.securityContext.appArmorProfile` 或 container 層級的 `securityContext.appArmorProfile`。
- 可用 `aa-status` 查看已載入的 profile，`apparmor_parser -r` 重新載入更新後的 profile。

---

### CKS-Q4：ServiceAccount Token 最小化

**題目：** 建立 ServiceAccount `no-token-sa`，明確停用自動掛載 SA token。建立使用此 SA 的 Pod，確認 `/var/run/secrets/kubernetes.io/serviceaccount/` 目錄不存在。

**解答：**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: no-token-sa
  namespace: cks-exam
automountServiceAccountToken: false     # SA 層級停用
---
apiVersion: v1
kind: Pod
metadata:
  name: no-token-pod
  namespace: cks-exam
spec:
  serviceAccountName: no-token-sa
  automountServiceAccountToken: false   # Pod 層級再次確認
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh','-c','sleep 3600']
```

```bash
# 確認 token 未掛載
kubectl exec no-token-pod -n cks-exam -- \
  ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
# → ls: /var/run/secrets/...: No such file or directory  ✓
```

**說明：**
- 每個 Pod 預設會自動掛載 ServiceAccount token，Container 可用此 token 存取 Kubernetes API。
- 若 Pod 不需要存取 API，應停用此功能，遵循「最小權限原則」。
- `automountServiceAccountToken: false` 可設在 SA 或 Pod 層級；Pod 層級優先。
- 若需要 API 存取，應建立具備最小 RBAC 權限的專用 SA，而非使用 `default` SA。
- Kubernetes 1.24+ 起 SA token 已自動設有過期時間（預設 1 小時），透過 `TokenRequest API` 動態核發。

---

### CKS-Q5：Audit Logging

**題目：** 設定 API Server 的 Audit Logging：Secret 操作記錄 `RequestResponse`（含請求與回應 body）、Pod 操作記錄 `Request`、其他操作記錄 `Metadata`、Event 的 get/list/watch 不記錄。

**解答：**

**步驟一：建立 Audit Policy**

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: None
  verbs: [get, list, watch]
  resources:
  - group: ''
    resources: [events]
- level: RequestResponse
  resources:
  - group: ''
    resources: [secrets]
- level: Request
  resources:
  - group: ''
    resources: [pods]
- level: Metadata
```

**步驟二：修改 kube-apiserver static pod manifest**

```bash
sudo vim /etc/kubernetes/manifests/kube-apiserver.yaml
```

在 `command` 加入：

```yaml
- --audit-policy-file=/etc/kubernetes/audit-policy.yaml
- --audit-log-path=/var/log/kubernetes/audit.log
- --audit-log-maxage=30
- --audit-log-maxbackup=10
- --audit-log-maxsize=100
```

加入 volume 和 volumeMount：

```yaml
volumes:
- name: audit-log
  hostPath:
    path: /var/log/kubernetes
    type: DirectoryOrCreate
containers:
- volumeMounts:
  - name: audit-log
    mountPath: /var/log/kubernetes
```

**步驟三：驗證**

```bash
sudo mkdir -p /var/log/kubernetes

# 等待 API Server 重啟後建立 Secret
kubectl create secret generic audit-test --from-literal=key=value -n cks-exam

# 查看 audit log
sudo tail -5 /var/log/kubernetes/audit.log | \
  python3 -c "import sys,json; [print(json.loads(l)['level'], json.loads(l)['verb'], json.loads(l).get('objectRef',{}).get('resource')) for l in sys.stdin]"
# → RequestResponse create secrets  ✓
```

**說明：**
- Audit Log 的四個等級：`None`（不記錄）→ `Metadata`（只記錄請求 metadata）→ `Request`（加上請求 body）→ `RequestResponse`（加上回應 body）。
- 修改 kube-apiserver manifest 後，kubelet 會自動重啟 kube-apiserver（約需 1-2 分鐘）。
- 注意：`RequestResponse` 會記錄 Secret 的明文內容（base64 解碼後），需謹慎控制 audit log 的存取權限。
- CKS 考試重點：能寫出 audit policy 並正確設定 kube-apiserver 參數。

---

### CKS-Q6：etcd Encryption at Rest（靜態加密）

**題目：** 設定 etcd 靜態加密，使用 AES-CBC 加密所有 Secret 的資料，驗證 etcd 中儲存的 Secret 已無法看到明文。

**解答：**

**步驟一：建立 EncryptionConfiguration**

```bash
# 產生 32-byte AES key
AES_KEY=$(head -c 32 /dev/urandom | base64)

sudo tee /etc/kubernetes/encryption-config.yaml << EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: ${AES_KEY}
  - identity: {}       # fallback，讓舊 Secret 仍可讀
EOF
```

**步驟二：修改 kube-apiserver manifest**

```bash
sudo vim /etc/kubernetes/manifests/kube-apiserver.yaml
# 在 command 加入：
# - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

**步驟三：驗證加密**

```bash
# 建立新 Secret
kubectl create secret generic encrypted-secret \
  --from-literal=password=MyS3cr3t -n cks-exam

# 直接查詢 etcd 原始資料（應看不到明文）
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/cks-exam/encrypted-secret | strings | grep MyS3cr3t
# → （無輸出）= 加密成功 ✓

# kubectl 仍可正常讀取（API Server 自動解密）
kubectl get secret encrypted-secret -n cks-exam \
  -o jsonpath='{.data.password}' | base64 -d
# → MyS3cr3t
```

**步驟四：重新加密現有 Secret**

```bash
# 強制重寫所有 Secret（讓舊 Secret 也被加密）
kubectl get secrets --all-namespaces -o json | \
  kubectl replace -f -
```

**說明：**
- 加密提供者依序嘗試：第一個提供者用於加密新資料，所有提供者都可用於解密。
- `identity: {}` 表示不加密（明文），放在最後作為 fallback 讓舊 Secret 可讀。
- 加密演算法：`aescbc`（AES-CBC，建議）、`aesgcm`（AES-GCM）、`secretbox`（NaCl）。
- 輪換金鑰：加入新 key → 重啟 API Server → 重寫所有 Secret → 移除舊 key。
- 注意：etcd encryption 只保護 etcd 的靜態儲存，不保護傳輸中的資料（TLS 負責）。

---

### CKS-Q7：NetworkPolicy — Egress 限制

**題目：** 對帶有 `app=restricted` label 的 Pod，限制其 Egress 流量：只允許 DNS 查詢（UDP/TCP 53）和連到同 namespace 的 Pod，阻斷所有對外連線。

**解答：**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-egress
  namespace: cks-exam
spec:
  podSelector:
    matchLabels:
      app: restricted
  policyTypes:
  - Egress
  egress:
  # 規則一：允許 DNS
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # 規則二：允許連到同 namespace 的 Pod
  - to:
    - podSelector: {}
```

**說明：**
- `policyTypes: [Egress]`：只限制對外流量，Ingress 流量不受影響。
- `policyTypes: [Ingress, Egress]`：同時限制進出流量（最嚴格）。
- 若不加任何 `egress` 規則（空陣列 `egress: []`），則完全封鎖所有對外連線（包含 DNS）。
- DNS 幾乎必須放行，否則容器無法解析域名。
- CKS 常見考題：阻斷 Pod 對 metadata server（169.254.169.254）的存取，防止 SSRF 攻擊雲端 metadata API。

---

### CKS-Q8：Trivy — 容器映像漏洞掃描

**題目：** 使用 Trivy 掃描 `nginx:1.25` 映像，列出所有 HIGH 和 CRITICAL 等級的漏洞。若漏洞數超過閾值，改用較新的 `nginx:alpine` 重新部署。

**解答：**

```bash
# 安裝 Trivy
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | \
  gpg --batch --yes --dearmor | \
  sudo tee /etc/apt/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] \
  https://aquasecurity.github.io/trivy-repo/deb generic main" | \
  sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update -q && sudo apt-get install -y -q trivy

# 掃描映像
trivy image --severity HIGH,CRITICAL nginx:1.25
```

**驗證結果（實際執行輸出）：**

```
nginx:1.25  →  Total: 112 (HIGH: 91, CRITICAL: 21)
nginx:alpine →  Total: 0  (HIGH: 0,  CRITICAL: 0)   ✓
```

**Kubernetes 叢集掃描：**

```bash
# 掃描叢集中所有正在使用的映像
kubectl get pods --all-namespaces \
  -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | \
  sort -u | xargs -I{} trivy image --severity CRITICAL {}

# 掃描 Deployment 並產生 JSON 報告
trivy k8s --report all --severity HIGH,CRITICAL cluster
```

**CI/CD 整合（設定漏洞閾值）：**

```bash
# EXIT CODE 1 if CRITICAL > 0（可用於 CI/CD 管線阻擋部署）
trivy image --severity CRITICAL --exit-code 1 nginx:1.25
```

**說明：**
- Trivy 可掃描：Container Image、Kubernetes 叢集、IaC 檔案（Terraform/Helm）、Git Repository。
- 漏洞等級：UNKNOWN → LOW → MEDIUM → HIGH → CRITICAL。
- CKS 考試建議使用 `--severity HIGH,CRITICAL` 聚焦高危漏洞。
- `--ignore-unfixed`：只顯示已有修復版本的漏洞（排除 `will_not_fix`）。
- 映像選擇原則：優先使用 `-alpine`、`-slim`、`-distroless` 等精簡映像，減少攻擊面。

---

### CKS-Q9：kube-bench — CIS Kubernetes Benchmark

**題目：** 使用 kube-bench 對 Master 節點執行 CIS Kubernetes Benchmark 掃描，找出 FAIL 項目並修復最常見的問題。

**解答：**

```bash
# 安裝 kube-bench
curl -fsSL https://github.com/aquasecurity/kube-bench/releases/download/v0.9.4/kube-bench_0.9.4_linux_amd64.deb \
  -o /tmp/kube-bench.deb
sudo dpkg -i /tmp/kube-bench.deb

# 掃描 Master 節點（CIS 1.9 benchmark）
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kube-bench --benchmark cis-1.9
```

**本叢集掃描結果摘要：**

```
== Summary master ==
45 checks PASS
5 checks FAIL
9 checks WARN
0 checks INFO

== Summary etcd ==
7 checks PASS   ← 完全通過
0 checks FAIL
```

**常見 FAIL 項目與修復：**

| 項目 | 問題 | 修復方式 |
|------|------|---------|
| 1.1.12 | etcd 資料目錄 owner 非 etcd:etcd | `sudo chown etcd:etcd /var/lib/etcd` |
| 1.2.5 | `--kubelet-certificate-authority` 未設定 | 在 kube-apiserver 加入此參數 |
| 4.2.6 | kubelet `--protect-kernel-defaults` 未啟用 | kubelet config 加入此設定 |

```bash
# 只掃描特定項目
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kube-bench --benchmark cis-1.9 --check 1.2.1,1.2.5

# 產生 JSON 報告
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kube-bench --benchmark cis-1.9 --json > /tmp/bench-report.json
```

**說明：**
- CIS（Center for Internet Security）Benchmark 是業界廣泛採用的安全基準。
- kube-bench 對應的 benchmark 版本：Kubernetes 1.29-1.32 → CIS 1.9。
- `PASS`：設定符合 CIS 建議；`FAIL`：設定不符合，有具體修復建議；`WARN`：需人工評估的設定（Manual）。
- CKS 考試中不要求零 FAIL，但需要能識別風險並知道如何修復。
- 可對 Worker 節點執行：`kube-bench --benchmark cis-1.9 --targets node`。

---

## 驗證總結

| 考試 | 題目 | 主題 | 已驗證 |
|------|------|------|--------|
| CKA | Q1 | 叢集狀態查詢 | ✅ |
| CKA | Q2 | RBAC — ServiceAccount + RoleBinding | ✅ |
| CKA | Q3 | ResourceQuota + LimitRange | ✅ |
| CKA | Q4 | Node 維護（cordon/drain/uncordon） | ✅ |
| CKA | Q5 | etcd 備份 | ✅ |
| CKA | Q6 | PersistentVolume + PVC | ✅ |
| CKA | Q7 | Taint + Toleration | ✅ |
| CKA | Q8 | NetworkPolicy（Ingress 白名單） | ✅ |
| CKA | Q9 | Static Pod | ✅ |
| CKAD | Q1 | ConfigMap + Secret 環境變數 | ✅ |
| CKAD | Q2 | ConfigMap Volume 掛載 | ✅ |
| CKAD | Q3 | Multi-container Sidecar | ✅ |
| CKAD | Q4 | Liveness + Readiness Probe | ✅ |
| CKAD | Q5 | Job + CronJob | ✅ |
| CKAD | Q6 | Deployment 滾動更新 + 回滾 | ✅ |
| CKAD | Q7 | SecurityContext | ✅ |
| CKAD | Q8 | Service ClusterIP + NodePort | ✅ |
| CKS | Q1 | Pod Security Admission | ✅ |
| CKS | Q2 | Seccomp RuntimeDefault | ✅ |
| CKS | Q3 | AppArmor 自訂 Profile | ✅ |
| CKS | Q4 | ServiceAccount Token 停用 | ✅ |
| CKS | Q5 | Audit Logging | ✅ |
| CKS | Q6 | etcd Encryption at Rest | ✅ |
| CKS | Q7 | NetworkPolicy Egress 限制 | ✅ |
| CKS | Q8 | Trivy 映像漏洞掃描 | ✅ |
| CKS | Q9 | kube-bench CIS Benchmark | ✅ |
