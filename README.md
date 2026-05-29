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

### 從 Host 直接使用 kubectl 連線到 Vagrant Master

Vagrant 建立的 Master 節點使用 Host-only 網路（`192.168.56.10:6443`），可從主機直接連線，無需每次 `vagrant ssh`。

#### 前置條件

- 主機已安裝 `kubectl`
- Vagrant 叢集已啟動（`vagrant up`）

#### 步驟

**1. 將 kubeconfig 從 Master 複製到主機**

```bash
mkdir -p ~/.kube
vagrant ssh k8s-master -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/config
```

**2. 確認 API Server 可連線**

```bash
curl -k https://192.168.56.10:6443/healthz
# 預期回應：ok
```

**3. 驗證叢集狀態**

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

#### 切換回 kind 叢集（若同時使用）

若主機同時有 kind 叢集，可合併 kubeconfig 並用 context 切換：

```bash
# 合併 kind kubeconfig
KUBECONFIG=~/.kube/config:<(kind get kubeconfig --name <cluster-name>) \
  kubectl config view --flatten > /tmp/merged && mv /tmp/merged ~/.kube/config

# 查看所有 context
kubectl config get-contexts

# 切換 context
kubectl config use-context kind-<cluster-name>   # 切到 kind
kubectl config use-context kubernetes-admin@kubernetes  # 切回 Vagrant
```

#### 移除 Vagrant 叢集 context（不再需要時）

```bash
kubectl config delete-cluster kubernetes
kubectl config delete-user kubernetes-admin
kubectl config delete-context kubernetes-admin@kubernetes
```

---

### 注意事項

1. **Vagrant Box**：預設使用 `bento/ubuntu-24.04`。若該 box 尚未發布，可在 `Vagrantfile` 第一行修改為 `bento/ubuntu-24.04`。
2. **佈建順序**：Vagrant 依定義順序依序佈建（master → worker1 → worker2），Worker 腳本會自動等待 Master 完成。
3. **VirtualBox Host-only 網路**：VirtualBox 6.1.28+ 預設允許 `192.168.56.0/21` 網段，本指南使用的 IP（192.168.56.10-12）在此範圍內。
4. **重新佈建**：若需重建叢集，執行 `vagrant destroy -f && vagrant up`。

---

## 常見問題與疑難排解

### 問題一：kubelet 無法啟動（Swap 啟用）

**錯誤訊息：**

```
failed to run Kubelet: running with swap on is not supported,
please disable swap or set --fail-swap-on flag to false
```

**根本原因：**

Kubernetes 的排程器（Scheduler）在決定將 Pod 放到哪個節點時，依賴節點回報的**真實可用記憶體**。當 Swap 啟用時，記憶體使用量變得難以預測：

| 情境 | 無 Swap | 有 Swap |
|------|---------|---------|
| 記憶體不足 | OOM Killer 立刻介入，Pod 被終止，K8s 可感知並重排 | 資料悄悄被 swap 到磁碟，Pod 沒死但速度劇降 |
| 排程決策 | 精確（`request`/`limit` 有意義） | 失真（Node 看起來有記憶體，實際卻在 swap I/O）|
| 延遲表現 | 可預測 | 磁碟 I/O 造成尖峰延遲，違反 QoS 保證 |

kubelet 在 v1.22+ 預設 `--fail-swap-on=true`，一旦偵測到 `/proc/swaps` 不為空，**直接拒絕啟動**。由於 kube-apiserver、etcd、kube-scheduler 等 Control Plane 元件都是由 kubelet 以 Static Pod 形式管理，kubelet 一旦無法啟動，整個 Control Plane 就跟著無法運作，`kubectl` 連線也會出現「connection refused」。

**封鎖效應示意圖：**

```
Swap 啟用
  → kubelet 拒絕啟動（fail-swap-on=true）
    → Static Pod 無法被管理
      → kube-apiserver 未啟動
        → kubectl: connection refused to :6443
```

**修復方式：**

對所有節點執行（master + worker）：

```bash
sudo swapoff -a                       # 立即關閉 swap（重開機前有效）
sudo sed -i '/swap/d' /etc/fstab      # 從 fstab 移除 swap 掛載，確保重開機後不再啟用
sudo systemctl restart kubelet
```

使用 Vagrant 時可批次修復：

```bash
for node in k8s-master k8s-worker1 k8s-worker2; do
  vagrant ssh $node -c \
    "sudo swapoff -a && sudo sed -i '/swap/d' /etc/fstab && sudo systemctl restart kubelet"
done
```

**驗證：**

```bash
# Swap 列應全為 0；kubelet 狀態應為 active
vagrant ssh k8s-master -c "free -h && sudo systemctl is-active kubelet"
```

---

### 問題二：kubectl 憑證驗證失敗（x509 錯誤）

**錯誤訊息：**

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
(possibly because of "crypto/rsa: verification error" while trying to verify
candidate authority certificate "kubernetes")
```

**根本原因：**

`~/.kube/config` 儲存的是**某次**從 VM 抓下來的憑證（CA cert + client cert/key）。若 VM 曾被 `vagrant destroy` 再重建，`kubeadm init` 會重新產生一組全新的 PKI，舊憑證就和 API Server 的不吻合：

```
本機 ~/.kube/config            VM kube-apiserver
  CA cert（舊）       ≠          CA cert（新，重建後重新簽發）
  client cert（舊）   ≠          能驗證的 CA（新）
          ↓
  x509: certificate signed by unknown authority
```

**修復方式：**

從 master 的 `/etc/kubernetes/admin.conf` 取得最新憑證，覆蓋本機 kubeconfig：

```bash
# Step 1：取得最新 admin.conf
vagrant ssh k8s-master -c "sudo cat /etc/kubernetes/admin.conf" > /tmp/fresh.conf

# Step 2：更新本機 kubeconfig 中的三組憑證資料
kubectl config set clusters.kubernetes.certificate-authority-data \
  $(KUBECONFIG=/tmp/fresh.conf kubectl config view --raw \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

kubectl config set users.kubernetes-admin.client-certificate-data \
  $(KUBECONFIG=/tmp/fresh.conf kubectl config view --raw \
    -o jsonpath='{.users[0].user.client-certificate-data}')

kubectl config set users.kubernetes-admin.client-key-data \
  $(KUBECONFIG=/tmp/fresh.conf kubectl config view --raw \
    -o jsonpath='{.users[0].user.client-key-data}')

# Step 3：切換到 Vagrant 叢集 context 並驗證
kubectl config use-context kubernetes-admin@kubernetes
kubectl get nodes
```

或者直接以 fresh.conf 操作，不動 `~/.kube/config`：

```bash
vagrant ssh k8s-master -c "sudo cat /etc/kubernetes/admin.conf" > /tmp/fresh.conf
KUBECONFIG=/tmp/fresh.conf kubectl get nodes
```

---

### 管理多個叢集 Context

本環境同時有 kind 與 Vagrant 兩個叢集，使用 `kubectl config` 在兩者之間切換：

```bash
# 查看所有 context
kubectl config get-contexts

# 切換到 Vagrant 3 節點叢集
kubectl config use-context kubernetes-admin@kubernetes

# 切換回 kind 叢集
kubectl config use-context kind-presit

# 查看目前使用中的 context
kubectl config current-context
```

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

# 存儲原理深度說明

本章從 Linux 磁碟掛載出發，逐層建立「為什麼 Kubernetes 存儲這樣設計」的完整認識。

---

## 一、基礎概念：Volume 是什麼？

### 1.1 容器存儲的根本問題

容器的檔案系統是**臨時的（Ephemeral）**。容器一旦重啟，所有寫入都消失。這帶來三個問題：

```
問題 1：資料持久性
  Pod 重啟 → rootfs 重置 → 資料遺失

問題 2：容器間共享
  同一 Pod 內 app + log-agent 兩個 container
  → 各自有獨立 rootfs → 無法直接共享 /log/

問題 3：設定注入
  映像 build 時不應寫死設定
  → ConfigMap / Secret 需要「掛入」容器
```

Kubernetes **Volume** 解決了這三個問題：Volume 的生命週期與 **Pod** 綁定（而非 container），Pod 內所有 container 可共享同一 Volume。

### 1.2 Volume 與 Linux mount 的關係

Kubernetes Volume 本質上就是 Linux **bind mount**：

```
主機目錄或設備   ──bind mount──►  容器內路徑
/var/lib/kubelet/pods/<uid>/volumes/...   →  /data
```

kubelet 負責在 Pod 啟動前完成 mount，在 Pod 刪除後執行 unmount。整個流程：

```
1. kubelet 收到 Pod spec
2. 準備 Volume（建立目錄、掛載 NFS、attach 雲端磁碟...）
3. 呼叫 containerd 建立 container
4. containerd 透過 OCI spec 將 Volume 路徑 bind mount 進 container
5. Pod 刪除 → container 停止 → kubelet unmount Volume
```

---

## 二、Volume 類型全覽

### 2.1 臨時 Volume（Pod 生命週期）

#### emptyDir

Pod 啟動時建立的**空目錄**，Pod 內所有 container 可共享，Pod 刪除後資料消失。

```yaml
volumes:
- name: shared-log
  emptyDir: {}          # 預設存在 node 的磁碟上
  # emptyDir:
  #   medium: Memory    # 改存在 tmpfs（RAM），更快但佔記憶體
  #   sizeLimit: 500Mi  # 限制大小
```

**典型用途：**
- Sidecar 模式：app container 寫 `/log/`，log-agent container 讀同一目錄
- 多階段計算：stage1 寫結果，stage2 讀取處理
- 暫存快取（medium: Memory 加速）

```
Pod
├── container: app      ─┐
│     mountPath: /log/   │  共享 emptyDir
└── container: log-agent─┘
      mountPath: /log/
```

#### 與 hostPath 的本質差異

| | emptyDir | hostPath |
|---|---|---|
| 生命週期 | 隨 Pod | 隨 Node（Pod 刪除資料仍在） |
| 跨 Node | 不同 Node 有不同資料 | 同上 |
| 安全性 | 安全 | 高風險（可讀 host 敏感檔案） |

### 2.2 Node 本地 Volume

#### hostPath

直接掛載**宿主機目錄或檔案**進容器。

```yaml
volumes:
- name: host-docker-sock
  hostPath:
    path: /var/run/docker.sock
    type: Socket          # 必須是 Socket 類型
```

**type 選項說明：**

| type | 行為 |
|---|---|
| `""` | 不做任何預檢 |
| `Directory` | 目錄必須已存在 |
| `DirectoryOrCreate` | 不存在則自動建立 |
| `File` | 檔案必須已存在 |
| `FileOrCreate` | 不存在則自動建立 |
| `Socket` | Unix socket 必須已存在 |
| `BlockDevice` | 區塊設備必須已存在 |

**安全風險：** hostPath 可存取 `/etc/`, `/var/lib/kubelet/` 等敏感路徑，CKS 試題中 hostPath 是常見的安全審查對象。生產環境應避免使用，或搭配 PSA 的 `restricted` policy 禁止。

#### local（靜態供應的 Local Volume）

比 hostPath 更正式，與 PV 系統整合，支援 node affinity：

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv
spec:
  capacity:
    storage: 100Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /mnt/data
  nodeAffinity:                      # ← 關鍵：強制 Pod 排程到同一 Node
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [k8s-worker1]
```

### 2.3 網路 Volume（跨 Node 存取）

#### NFS

最簡單的網路共享存儲：

```yaml
volumes:
- name: nfs-vol
  nfs:
    server: 192.168.56.100    # NFS server IP
    path: /exports/data
    readOnly: false
```

NFS Volume 的特性：
- 多個 Pod 同時讀寫（支援 ReadWriteMany）
- 不需要 CSI 驅動，kubelet 直接掛載
- 效能受網路延遲影響

#### ConfigMap / Secret as Volume

ConfigMap 和 Secret 也是 Volume 的一種，每個 key 對應容器內的一個**檔案**：

```yaml
volumes:
- name: app-config
  configMap:
    name: my-config
    items:                    # 可選：只掛載特定 key
    - key: app.properties
      path: app.properties    # 容器內檔案名
      mode: 0444              # 檔案權限
```

```
ConfigMap: my-config
  key: app.properties  →  /etc/config/app.properties
  key: log.conf        →  /etc/config/log.conf
```

**重要行為：**
- Volume 掛載的 ConfigMap **會自動同步**（約 1 分鐘）
- 環境變數注入的 ConfigMap **不會自動更新**（需重啟 Pod）
- Secret Volume 掛載後儲存在 **tmpfs**（記憶體），不寫磁碟

---

## 三、PersistentVolume 系統

### 3.1 設計動機：解耦存儲供應與消費

直接在 Pod spec 中寫 NFS server IP 有幾個問題：
1. 開發者需要知道基礎設施細節（IP、路徑）
2. 存儲配置散落在各 Pod spec 中，難以統一管理
3. 無法做容量控管

Kubernetes 引入 **PV / PVC** 兩層抽象：

```
管理員視角                     開發者視角
┌─────────────────┐           ┌──────────────────┐
│ PersistentVolume│           │PersistentVolume   │
│ (PV)            │◄──Bind────│Claim (PVC)        │
│                 │           │                  │
│ 實際存儲資源     │           │「我要 10Gi RWO」  │
│ NFS/Cloud Disk  │           │不關心底層是什麼   │
└─────────────────┘           └──────────────────┘
         ▲                              ▲
    管理員建立                     開發者建立
    或 StorageClass               在 Pod 中引用
    動態供應
```

### 3.2 PV 完整規格解析

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-example
spec:
  capacity:
    storage: 10Gi              # 容量宣告
  accessModes:
  - ReadWriteOnce              # 存取模式（見下方說明）
  persistentVolumeReclaimPolicy: Retain  # 回收策略
  storageClassName: standard   # StorageClass 名稱
  mountOptions:                # 掛載選項（傳給 mount 指令）
  - hard
  - nfsvers=4.1
  nfs:                         # 後端存儲類型
    server: 192.168.56.100
    path: /exports/pv-example
```

### 3.3 AccessMode（存取模式）深度說明

存取模式描述的是**同時**可以有多少 Node 掛載此 Volume：

| AccessMode | 縮寫 | 含義 |
|---|---|---|
| `ReadWriteOnce` | RWO | 只能被**一個 Node** 以讀寫方式掛載 |
| `ReadOnlyMany` | ROX | 可以被**多個 Node** 以唯讀方式掛載 |
| `ReadWriteMany` | RWX | 可以被**多個 Node** 以讀寫方式掛載 |
| `ReadWriteOncePod` | RWOP | 只能被**一個 Pod** 以讀寫方式掛載（v1.22+） |

**關鍵誤解澄清：** RWO 是 **Node** 層級，不是 Pod 層級。同一個 Node 上的多個 Pod 都可以掛載同一個 RWO PV。RWOP 才是真正的單 Pod 獨佔。

```
RWO 誤解圖：
  Node A
  ├── Pod-1 ──┐
  └── Pod-2 ──┴── PV (RWO) ← 合法！同一 Node 的兩個 Pod

  Node A ──── PV (RWO)  ← 合法
  Node B ──── PV (RWO)  ← 不合法！RWO 只允許一個 Node
```

**後端存儲對 AccessMode 的支援（常考）：**

| 存儲類型 | RWO | ROX | RWX |
|---|---|---|---|
| hostPath | ✅ | ❌ | ❌ |
| NFS | ✅ | ✅ | ✅ |
| AWS EBS | ✅ | ❌ | ❌ |
| GCE PD | ✅ | ✅ | ❌ |
| Azure Disk | ✅ | ❌ | ❌ |
| CephFS | ✅ | ✅ | ✅ |

### 3.4 ReclaimPolicy（回收策略）

PVC 刪除後，PV 如何處理？

#### Retain（保留）

```
PVC 刪除
  → PV 狀態變為 Released（不可被新 PVC 綁定）
  → 管理員需手動介入：
      1. 備份或確認資料
      2. 刪除 PV（資料留在後端）
      3. 重新建立 PV 供再次使用
  → 後端存儲（NFS 目錄、雲端磁碟）資料不自動刪除
```

#### Delete

```
PVC 刪除
  → PV 狀態變為 Terminating
  → Kubernetes 自動刪除 PV 物件
  → 後端存儲也一起刪除（例：AWS EBS volume 被 delete）
  → 資料永久消失！
```

#### 狀態機

```
PV 完整生命週期：

Available ──(PVC binding)──► Bound ──(PVC delete, Retain)──► Released
    ▲                                                             │
    └──────────── 手動清理 claimRef 後重新 Available ◄────────────┘

Available ──(PVC binding)──► Bound ──(PVC delete, Delete)──► [PV 消失]
```

### 3.5 PVC 綁定規則

PVC 尋找 PV 時，必須**同時**滿足：

```
1. capacity：PV 容量 ≥ PVC 申請量
2. accessModes：PV 支援 PVC 要求的所有模式
3. storageClassName：完全相符（包含空字串）
4. volumeMode：Filesystem 或 Block 一致
5. selector（可選）：PVC 可用 label selector 指定 PV
```

**綁定是「最小滿足」但不保證最小浪費：**

```
現有 PV：10Gi, 50Gi, 100Gi
PVC 申請：8Gi

→ 系統會綁定 10Gi 的 PV（最小滿足）
→ 但若只有 50Gi 和 100Gi，會綁 50Gi（浪費 42Gi）
→ 不會因浪費而拒絕綁定
```

---

## 四、StorageClass 與動態供應

### 4.1 靜態供應 vs 動態供應

```
靜態供應（Static Provisioning）：
  管理員 → 手動建立 PV → 開發者建立 PVC → 自動綁定

動態供應（Dynamic Provisioning）：
  管理員 → 建立 StorageClass → 開發者建立 PVC → 自動建立 PV + 綁定
                                                        ↑
                                               StorageClass 中的
                                               Provisioner 負責
```

### 4.2 StorageClass 規格

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"  # 設為預設 SC
provisioner: kubernetes.io/aws-ebs          # 哪個 Provisioner 處理
parameters:                                  # 傳給 Provisioner 的參數
  type: gp3
  iopsPerGB: "50"
  encrypted: "true"
reclaimPolicy: Delete                        # 動態建立的 PV 的回收策略
allowVolumeExpansion: true                   # 允許擴容 PVC
volumeBindingMode: WaitForFirstConsumer      # 見下方說明
mountOptions:
- debug
```

### 4.3 volumeBindingMode 關鍵差異

| 模式 | 行為 | 適用場景 |
|---|---|---|
| `Immediate` | PVC 建立後**立即**尋找/建立 PV | NFS、Ceph 等共享存儲 |
| `WaitForFirstConsumer` | 等到 Pod 被**排程到 Node** 後才供應 PV | Local Volume、CSI 拓撲感知 |

**為什麼需要 WaitForFirstConsumer？**

```
問題場景（Immediate 模式 + Local Volume）：
  PVC 建立 → 立即在 Node A 建立 PV
  Pod 因 Node Affinity 只能去 Node B
  → Pod 永遠 Pending！（PV 在 Node A，Pod 要去 Node B）

解法（WaitForFirstConsumer）：
  PVC 建立 → 等待
  Pod 排程器決定 Pod 去 Node B
  → 在 Node B 建立 PV
  → Pod 和 PV 在同一 Node → 正常運行
```

### 4.4 Default StorageClass

若 PVC **不指定** `storageClassName`，且叢集有預設 StorageClass，會自動使用預設 SC 動態供應：

```bash
# 查看預設 StorageClass（有 (default) 標記）
kubectl get sc
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

若 PVC 明確設 `storageClassName: ""`，代表**不使用** StorageClass，只綁定靜態 PV。

---

## 五、CSI 架構原理

### 5.1 為什麼需要 CSI？

Kubernetes 早期將存儲驅動（如 AWS EBS、GCE PD）直接編譯進 kubelet（In-tree 插件）。問題：
- 更新存儲驅動 → 必須升級整個 Kubernetes
- 第三方廠商無法獨立釋出驅動
- Bug 修復週期與 K8s release 耦合

**CSI（Container Storage Interface）** 將存儲驅動從 K8s core 中分離：

```
舊架構（In-tree）：
  kubelet ──直接呼叫──► AWS EBS API
           ──直接呼叫──► GCE PD API
           ──直接呼叫──► ...（編譯在一起）

新架構（CSI）：
  kubelet ──gRPC──► CSI Node Plugin（DaemonSet，每個 Node 一個）
                         │
                         └──► 存儲後端（AWS EBS / Ceph / NFS...）

  Controller Manager ──gRPC──► CSI Controller Plugin（Deployment）
                                    │
                                    └──► 建立/刪除後端 Volume
```

### 5.2 CSI 組件架構圖

```
Control Plane
┌─────────────────────────────────────────────────────┐
│  kube-controller-manager                            │
│    AttachDetachController  ──────────────────────┐  │
│    PVController (動態供應)  ──────────────────┐   │  │
└─────────────────────────────────────────────── │ ──│─┘
                                                 │   │
                            ┌────────────────────▼───▼──┐
                            │  CSI Controller Plugin    │
                            │  (Deployment, 1~3 replicas)│
                            │  - CreateVolume           │
                            │  - DeleteVolume           │
                            │  - ControllerPublish      │
                            │    (attach to Node)       │
                            └───────────────────────────┘

Worker Node
┌─────────────────────────────────────────────────────┐
│  kubelet                                            │
│    VolumeManager  ────────────────────────────────┐ │
└────────────────────────────────────────────────── │ ┘
                                                    │
                        ┌───────────────────────────▼──┐
                        │  CSI Node Plugin             │
                        │  (DaemonSet，每個 Node 一個)  │
                        │  - NodeStageVolume           │
                        │    (global mount)            │
                        │  - NodePublishVolume         │
                        │    (bind mount to Pod)       │
                        └──────────────────────────────┘
```

### 5.3 CSI Volume 生命週期（以動態供應為例）

```
開發者建立 PVC
    │
    ▼
PVController 呼叫 CSI Controller Plugin
    │  CreateVolume → 在後端建立真實磁碟（如 AWS EBS）
    │  回傳 volumeID
    ▼
PV 物件自動建立，PVC 狀態變 Bound
    │
    ▼
Pod 被排程到 Node X
    │
    ▼
AttachDetachController 呼叫 CSI Controller Plugin
    │  ControllerPublishVolume → 將磁碟 attach 到 Node X
    ▼
kubelet 的 VolumeManager 呼叫 CSI Node Plugin
    │  NodeStageVolume → 格式化並掛載到 Node 的 staging 目錄
    │    /var/lib/kubelet/plugins/kubernetes.io/csi/pv/<pv-name>/globalmount
    │  NodePublishVolume → bind mount 到 Pod 的 Volume 路徑
    │    /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pv-name>/mount
    ▼
容器啟動，/data 可用
```

### 5.4 常見 CSI 驅動

| 驅動 | 提供者 | 支援 AccessMode |
|---|---|---|
| `ebs.csi.aws.com` | AWS | RWO |
| `pd.csi.storage.gke.io` | GKE | RWO, ROX |
| `disk.csi.azure.com` | Azure | RWO |
| `file.csi.azure.com` | Azure Files | RWO, ROX, RWX |
| `rbd.csi.ceph.com` | Ceph RBD | RWO, ROX |
| `cephfs.csi.ceph.com` | CephFS | RWO, ROX, RWX |
| `nfs.csi.k8s.io` | community NFS | RWO, ROX, RWX |

---

## 六、StatefulSet 與存儲

### 6.1 StatefulSet 為什麼需要特殊存儲處理？

Deployment 中的 Pod 是**無狀態的、可互換的**，所有 Pod 共享同一個 PVC 沒有問題（若後端支援 RWX）。

但 StatefulSet 的 Pod 是**有身份的**：
- `mysql-0`, `mysql-1`, `mysql-2` 各自代表不同的資料庫實例
- 每個 Pod 需要自己**獨立的** PVC（各自的存儲空間）
- Pod 重建後必須掛載**相同的** PVC（資料不能錯位）

### 6.2 volumeClaimTemplate

StatefulSet 透過 `volumeClaimTemplates` 為每個 Pod **自動建立獨立 PVC**：

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql-headless
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  template:
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:          # ← 模板，不是直接的 PVC
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 20Gi
```

自動建立的 PVC 命名規則：`<template-name>-<statefulset-name>-<ordinal>`

```
StatefulSet: mysql, replicas: 3
→ 自動建立：
  data-mysql-0  (20Gi, RWO)
  data-mysql-1  (20Gi, RWO)
  data-mysql-2  (20Gi, RWO)

mysql-0 重建 → 自動掛回 data-mysql-0（不會誤掛 data-mysql-1）
```

### 6.3 StatefulSet 縮容與 PVC 的行為

**StatefulSet 縮容時，PVC 不會自動刪除：**

```bash
# 縮容從 3 到 1
kubectl scale statefulset mysql --replicas=1
# → mysql-1, mysql-2 Pod 被刪除
# → data-mysql-1, data-mysql-2 PVC 仍然存在！

# 再擴容到 3
kubectl scale statefulset mysql --replicas=3
# → mysql-1, mysql-2 重建，自動掛回原來的 PVC（資料完整保留）
```

設計原則：StatefulSet **刻意**保留 PVC，防止意外縮容導致資料遺失。若確認要刪除，需手動刪除 PVC。

---

## 七、Volume 安全性與進階特性

### 7.1 fsGroup 與 Volume 權限

容器預設以 `runAsUser` 指定的 UID 執行，但 Volume 目錄的 owner 可能是 root，導致無法寫入：

```yaml
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000          # ← Volume 目錄的 GID 會被設為 2000
                           #   且 Pod 內的 process 會有 supplementary group 2000
  containers:
  - name: app
    volumeMounts:
    - name: data
      mountPath: /data
```

```
kubelet 掛載 Volume 後執行：
  chown :2000 /data       （GID 改為 fsGroup）
  chmod g+rw /data        （群組可讀寫）

容器內 process（UID=1000, GID=3000, supplementary=2000）
  → 有 GID 2000 → 可以讀寫 /data
```

### 7.2 readOnlyRootFilesystem 與 Volume

CKS 常考：`readOnlyRootFilesystem: true` 使根檔案系統唯讀，但容器往往需要寫入暫存目錄：

```yaml
containers:
- name: app
  securityContext:
    readOnlyRootFilesystem: true
  volumeMounts:
  - name: tmp
    mountPath: /tmp          # 應用程式需要寫 /tmp
  - name: var-run
    mountPath: /var/run      # 需要 PID file
volumes:
- name: tmp
  emptyDir: {}               # 用 emptyDir 提供可寫路徑
- name: var-run
  emptyDir: {}
```

### 7.3 subPath — 共享 Volume 中的子目錄

多個 container 共享同一 PVC 但各自使用不同子目錄：

```yaml
containers:
- name: app1
  volumeMounts:
  - name: shared
    mountPath: /data
    subPath: app1             # 實際掛載 PV 內的 app1/ 子目錄
- name: app2
  volumeMounts:
  - name: shared
    mountPath: /data
    subPath: app2             # 實際掛載 PV 內的 app2/ 子目錄
volumes:
- name: shared
  persistentVolumeClaim:
    claimName: shared-pvc
```

```
PV 目錄結構：
/
├── app1/   ← app1 container 的 /data
└── app2/   ← app2 container 的 /data
```

**注意：** 使用 `subPath` 時，ConfigMap/Secret 的自動更新**不生效**（K8s 已知限制）。

### 7.4 Volume 擴容（Volume Expansion）

前提：StorageClass 設定 `allowVolumeExpansion: true`，且後端支援線上擴容。

```bash
# 直接編輯 PVC 的 storage 大小（只能增加，不能縮小）
kubectl patch pvc my-pvc -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# 觀察擴容狀態
kubectl describe pvc my-pvc
# Conditions:
#   FileSystemResizePending  → 正在擴容（Pod 需要 restart 才能看到新空間，視後端而定）
#   Resizing                 → 後端磁碟正在擴容
```

---

## 八、存儲問題排查指引

### 8.1 診斷流程

```
Pod 狀態：Pending
    │
    ▼
kubectl describe pod <name>
    │
    ├── "persistentvolumeclaim ... not found"
    │     → PVC 名稱拼錯，或在不同 namespace
    │
    ├── "no persistent volumes available for this claim"
    │     → 找不到符合條件的 PV（容量/accessMode/storageClass 不符）
    │
    ├── "waiting for a volume to be created"
    │     → StorageClass 動態供應等待中，或 Provisioner 有問題
    │
    └── "volume ... is already exclusively attached to one node"
          → RWO 的 Volume 已 attach 到另一個 Node（常見於 Node 故障後的 Pod 遷移）
```

### 8.2 常見問題與解法

| 症狀 | 根本原因 | 解法 |
|---|---|---|
| PVC 一直 Pending | 無符合的 PV | 檢查 PV capacity/accessMode/storageClass |
| PV 狀態 Released（無法再綁定） | ReclaimPolicy=Retain，舊 PVC 刪除 | 手動刪除 PV 的 `claimRef` 欄位 |
| Pod Pending：volume node affinity conflict | PV 建立在錯誤的 Node | 確認 SC 使用 WaitForFirstConsumer |
| 容器無法寫入 Volume | UID/GID 權限問題 | 設定 `securityContext.fsGroup` |
| StatefulSet 擴容後 PVC 無法建立 | StorageClass 不存在或 Provisioner 故障 | 檢查 `kubectl get sc` 和 Provisioner Pod |
| ConfigMap Volume 更新不生效 | 使用了 `subPath` | 改用完整 mountPath，或手動重啟 Pod |

### 8.3 實用排查指令

```bash
# 查看 PV 和 PVC 的綁定狀態
kubectl get pv,pvc -A

# 查看 PV 詳細資訊（含 claimRef）
kubectl describe pv <pv-name>

# 查看 StorageClass
kubectl get sc

# 查看 PVC 的事件（排查供應失敗）
kubectl describe pvc <pvc-name> -n <namespace>

# 查看 CSI 節點驅動狀態
kubectl get csinodes
kubectl get csidrivers

# 查看 kubelet 的 Volume 掛載（在 Node 上執行）
ls /var/lib/kubelet/pods/
mount | grep kubernetes

# 檢查 PV 是否有孤兒 claimRef（Released 狀態無法重用）
kubectl get pv -o json | jq '.items[] | select(.status.phase=="Released") | {name:.metadata.name, claim:.spec.claimRef}'
```

---

## 存儲知識結構總結

```
存儲架構全景：

應用層（開發者）
  PVC ──────────────────────────────────────────────────────► Pod Volume Mount
   │                                                              │
   │ 綁定                                                         │ bind mount
   ▼                                                              ▼
  PV ◄──────── StorageClass（動態）  Container rootfs (/data)
   │              │  Provisioner              │
   │              ▼                           │
   │         CSI Controller Plugin        emptyDir / hostPath
   │              │                      ConfigMap / Secret
   ▼              ▼
後端存儲（NFS / AWS EBS / Ceph / Local Disk）

關鍵設計原則：
  ┌────────────────────────────────────────────────────┐
  │ 1. Volume 生命週期與 Pod 綁定，PV 生命週期獨立      │
  │ 2. PVC 是「存儲申請」，PV 是「存儲資源」            │
  │ 3. StorageClass 抽象後端差異，Provisioner 動態供應  │
  │ 4. AccessMode 是 Node 層級（除 RWOP 是 Pod 層級）   │
  │ 5. StatefulSet 的 PVC 縮容後保留（防資料遺失）      │
  │ 6. CSI 將存儲驅動從 K8s core 解耦（DaemonSet+Deploy）│
  └────────────────────────────────────────────────────┘
```

---

# 身份識別與存取控制原理

本章說明 Kubernetes 如何識別「你是誰」（認證）、「你能做什麼」（RBAC 授權），以及 ServiceAccount 如何讓 Pod 安全地與 API Server 互動。

---

## 一、請求進入 API Server 的完整流程

每一個對 Kubernetes API 的請求，都要經過三道關卡：

```
kubectl / Pod / Controller
        │
        │ HTTPS 請求
        ▼
┌─────────────────────────────────────────────────────────┐
│                    kube-apiserver                       │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ 1. 認證       │→ │ 2. 授權       │→ │ 3. 准入控制   │  │
│  │ Authentication│  │ Authorization│  │  Admission   │  │
│  │               │  │  (RBAC)      │  │  Controller  │  │
│  │ 你是誰？      │  │ 你能做什麼？  │  │ 合規嗎？     │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│         │                │                  │           │
│      401 Unauthorized  403 Forbidden     400/422        │
└─────────────────────────────────────────────────────────┘
        │（三關都過）
        ▼
    etcd 讀寫 / 物件處理
```

### 1.1 認證（Authentication）

API Server 支援多種認證方式，同時啟用，任一通過即算認證成功：

| 認證方式 | 典型用途 | 識別結果 |
|---|---|---|
| X.509 用戶端憑證 | `kubectl`（admin.conf）、kubelets | `CN=system:node:k8s-worker1` |
| Bearer Token（JWT） | ServiceAccount Pod | `system:serviceaccount:default:my-sa` |
| Bootstrap Token | kubeadm join 時 | `system:bootstrap:<token-id>` |
| OIDC Token | 整合外部 IdP（如 Dex、Keycloak） | 由 IdP 提供 username/groups |
| Static Token File | 測試用（不推薦生產） | 設定檔指定 |

認證後，API Server 得到兩個關鍵屬性：
- **Username**（如 `kubernetes-admin`、`system:serviceaccount:default:my-sa`）
- **Groups**（如 `system:masters`、`system:authenticated`）

### 1.2 認證失敗 vs 授權失敗的差別

```bash
# 認證失敗（401）：API Server 不認識你
curl -k https://192.168.56.10:6443/api/v1/pods
# {"message":"Unauthorized"}

# 認證成功但授權失敗（403）：知道你是誰，但你沒有權限
kubectl auth can-i delete pods --as=system:serviceaccount:default:my-sa
# no
```

---

## 二、RBAC 模型深度說明

### 2.1 核心三要素

RBAC（Role-Based Access Control）的本質是一張**三維映射表**：

```
Subject（誰）× Verb（做什麼）× Resource（對什麼）→ 允許 / 拒絕
```

```
Subject 種類：
  User        → kubectl 使用者（X.509 CN，K8s 不管理 User 物件）
  Group       → 使用者群組（X.509 O，或 OIDC groups claim）
  ServiceAccount → Pod 的身份

Verb 種類：
  get, list, watch          → 讀取
  create, update, patch     → 寫入
  delete, deletecollection  → 刪除
  use, bind, escalate       → 特殊（PSP、Role 相關）
  *                         → 所有操作

Resource 種類：
  pods, deployments, services, secrets...
  pods/log, pods/exec, pods/portforward   ← subresource（斜線分隔）
  *                                        ← 所有資源
```

### 2.2 Role vs ClusterRole：作用域差異

```
Role（namespace 範圍）          ClusterRole（叢集範圍）
┌─────────────────────┐        ┌──────────────────────────┐
│  namespace: dev     │        │  叢集所有 namespace       │
│  ┌───────────────┐  │        │  ┌────────────────────┐  │
│  │ Role          │  │        │  │ ClusterRole        │  │
│  │ pod-reader    │  │        │  │ cluster-admin      │  │
│  │ get,list pods │  │        │  │ * on *             │  │
│  └───────────────┘  │        │  └────────────────────┘  │
└─────────────────────┘        └──────────────────────────┘

RoleBinding 可以綁定：          ClusterRoleBinding 只能綁定：
  Role（同 namespace）            ClusterRole
  ClusterRole（降級為 namespace 範圍使用）

⚠️ 重要：ClusterRole + RoleBinding（不是 ClusterRoleBinding）
         → 只在 RoleBinding 所在的 namespace 生效
```

**作用域矩陣（常考）：**

| 組合 | 生效範圍 |
|---|---|
| Role + RoleBinding | 單一 namespace |
| ClusterRole + RoleBinding | 單一 namespace（ClusterRole 降級） |
| ClusterRole + ClusterRoleBinding | 整個叢集 |
| Role + ClusterRoleBinding | ❌ 不合法 |

### 2.3 RBAC 物件完整範例

```yaml
# Step 1: 定義 Role（namespace 範圍的權限）
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: dev
rules:
- apiGroups: [""]              # "" 代表 core API group（Pod、Service、ConfigMap...）
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]      # subresource
  verbs: ["get"]
- apiGroups: ["apps"]          # apps group（Deployment、StatefulSet...）
  resources: ["deployments"]
  verbs: ["get", "list"]

---
# Step 2: 綁定（RoleBinding）
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: dev
subjects:
- kind: ServiceAccount
  name: my-app-sa
  namespace: dev              # SA 的 namespace（跨 namespace 時必須指定）
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
- kind: Group
  name: dev-team
  apiGroup: rbac.authorization.k8s.io
roleRef:                       # roleRef 一旦建立不可修改（需刪除重建）
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### 2.4 apiGroups 對照表

Kubernetes API 按功能分組，RBAC rules 中必須填寫正確的 apiGroup：

| apiGroup | 包含的資源 |
|---|---|
| `""` (core) | Pod, Service, ConfigMap, Secret, PVC, Node, Namespace, SA |
| `apps` | Deployment, StatefulSet, DaemonSet, ReplicaSet |
| `batch` | Job, CronJob |
| `networking.k8s.io` | Ingress, NetworkPolicy |
| `rbac.authorization.k8s.io` | Role, ClusterRole, RoleBinding, ClusterRoleBinding |
| `storage.k8s.io` | StorageClass, PersistentVolume |
| `policy` | PodDisruptionBudget |

```bash
# 查詢資源屬於哪個 apiGroup
kubectl api-resources --sort-by name | grep -E "^NAME|deployment|ingress|networkpol"
# NAME              SHORTNAMES   APIVERSION              NAMESPACED
# deployments       deploy       apps/v1                 true
# ingresses         ing          networking.k8s.io/v1    true
# networkpolicies   netpol       networking.k8s.io/v1    true
```

### 2.5 內建 ClusterRole

Kubernetes 預設提供幾個重要的 ClusterRole：

| ClusterRole | 用途 |
|---|---|
| `cluster-admin` | 完整叢集管理員（等同 root） |
| `admin` | namespace 管理員（可管理 RBAC 以外的所有資源） |
| `edit` | 可讀寫大多數資源，但不能改 RBAC |
| `view` | 唯讀，不能看 Secret |
| `system:node` | kubelet 所需的最小權限 |
| `system:kube-proxy` | kube-proxy 所需權限 |

### 2.6 RBAC 驗證指令

```bash
# 確認自己有什麼權限
kubectl auth can-i --list

# 模擬其他身份（impersonation，需有 impersonate 權限）
kubectl auth can-i list pods --as=system:serviceaccount:dev:my-sa
kubectl auth can-i list pods --as=system:serviceaccount:dev:my-sa -n dev

# 查看某個 SA 的所有 RoleBinding/ClusterRoleBinding
kubectl get rolebindings,clusterrolebindings -A -o json | \
  jq '.items[] | select(.subjects[]? | .kind=="ServiceAccount" and .name=="my-sa")'
```

---

## 三、ServiceAccount 深度說明

### 3.1 ServiceAccount 的設計目的

**User** 代表人類使用者，**ServiceAccount（SA）** 代表 **Pod（程式）的身份**：

```
人類管理員                       Pod 中的應用程式
    │                                  │
    │ kubectl（X.509 cert）             │ HTTP 呼叫 K8s API
    │ Username: kubernetes-admin       │ 需要身份來取得授權
    ▼                                  ▼
kube-apiserver                    kube-apiserver
    認證 → RBAC 授權                   認證 → RBAC 授權
                                       ↑
                               ServiceAccount Token
                               自動掛載進 Pod
```

### 3.2 ServiceAccount Token 演進

**舊版（K8s 1.23 以前）：Secret-based Token**

```
建立 SA → 自動建立 Secret（type: kubernetes.io/service-account-token）
→ Secret 中有永不過期的 JWT token
→ 自動掛載到 /var/run/secrets/kubernetes.io/serviceaccount/token
```

問題：Token **永不過期**，若 Secret 洩漏風險極高。

**新版（K8s 1.24+）：Projected Token（TokenRequest API）**

```
Pod 啟動 → kubelet 向 TokenRequest API 申請短期 token
→ 預設有效期 1 小時（由 kube-apiserver --service-account-max-token-expiration 控制）
→ kubelet 自動在過期前 80% 時間點更新
→ 掛載方式變為 projected volume（不再是 Secret）
```

```yaml
# 新版 projected volume（kubelet 自動注入，無需手動設定）
volumes:
- name: kube-api-access
  projected:
    sources:
    - serviceAccountToken:
        expirationSeconds: 3607    # 自動輪換
        path: token
    - configMap:
        name: kube-root-ca.crt     # CA 憑證
        items:
        - key: ca.crt
          path: ca.crt
    - downwardAPI:
        items:
        - path: namespace
          fieldRef:
            fieldPath: metadata.namespace
```

### 3.3 Pod 中 SA Token 的掛載路徑

```bash
# 在 Pod 內查看自動掛載的 token
ls /var/run/secrets/kubernetes.io/serviceaccount/
# ca.crt    namespace    token

# 使用 token 呼叫 API Server
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

curl -s --cacert $CA \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/$NAMESPACE/pods
```

### 3.4 SA 安全最佳實踐

**問題：default SA 被所有 Pod 自動使用**

```
namespace: production
├── Pod A（沒指定 SA）→ 自動使用 default SA
├── Pod B（沒指定 SA）→ 自動使用 default SA
└── Pod C（沒指定 SA）→ 自動使用 default SA

若 default SA 被授予過高權限 → 任一 Pod 被入侵都可存取 API
```

**正確做法：最小權限原則**

```yaml
# 1. 為應用建立專用 SA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-service-sa
  namespace: production

---
# 2. 只授予必要權限
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: order-service-role
  namespace: production
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["order-config"]   # 只能讀特定 ConfigMap（resourceNames 限縮）
  verbs: ["get"]

---
# 3. Pod 明確指定 SA，停用不需要的 token
spec:
  serviceAccountName: order-service-sa
  automountServiceAccountToken: false   # 若完全不需要 API 存取
```

### 3.5 跨 Namespace 授權

SA 是 namespace 資源，跨 namespace 授權需要在 RoleBinding 中明確指定 SA 的 namespace：

```yaml
# 允許 monitoring namespace 的 prometheus SA 讀取 production namespace 的 Pod
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-pod-reader
  namespace: production          # ← RoleBinding 在 production namespace
subjects:
- kind: ServiceAccount
  name: prometheus
  namespace: monitoring          # ← SA 在不同的 namespace
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

---

## 四、RBAC 問題排查指引

```
問題：Pod 呼叫 API 收到 403 Forbidden

排查步驟：
1. 確認 Pod 使用哪個 SA
   kubectl get pod <name> -o jsonpath='{.spec.serviceAccountName}'

2. 確認 SA 有哪些 binding
   kubectl get rolebindings,clusterrolebindings -A \
     -o custom-columns='NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects' | grep <sa-name>

3. 模擬該 SA 的權限
   kubectl auth can-i <verb> <resource> \
     --as=system:serviceaccount:<namespace>:<sa-name> -n <namespace>

4. 查看 API Server audit log 確認拒絕原因
   grep "403" /var/log/kubernetes/audit.log | jq '.user,.verb,.objectRef'
```

| 症狀 | 原因 | 解法 |
|---|---|---|
| `403 Forbidden` | SA 無對應 RoleBinding | 建立 RoleBinding |
| `403` 但 RoleBinding 存在 | apiGroup 填錯（如用 `apps` 但資源在 core）| 確認 `kubectl api-resources` |
| ClusterRoleBinding 建立但只在部分 ns 生效 | 用了 RoleBinding 而非 ClusterRoleBinding | 確認 binding 種類 |
| Pod 使用 wrong SA | 沒有指定 `serviceAccountName` | 明確指定 SA 名稱 |
| Token 掛載但 API 回 401 | Token 過期或 SA 被刪除重建（token 失效） | 重啟 Pod 取得新 token |

---

# NetworkPolicy 原理深度說明

本章說明 NetworkPolicy 的選擇器語義、CNI 實作機制，以及四種 default-deny 模式的完整圖解。

---

## 一、NetworkPolicy 的本質

NetworkPolicy 是 Kubernetes **宣告式的 L3/L4 防火牆規則**，定義 Pod 可以與誰通訊：

```
沒有 NetworkPolicy 的叢集（預設）：
  任何 Pod ←→ 任何 Pod（無限制）
  任何 Pod ←→ 任何外部 IP（無限制）

有 NetworkPolicy 後：
  只有「被允許的流量」才能通過
  沒有明確允許 = 拒絕（當 Pod 被至少一條 NP 選中時）
```

**重要前提：NetworkPolicy 需要 CNI 插件支援才能生效。**

| CNI | 支援 NetworkPolicy |
|---|---|
| Flannel（純 VXLAN） | ❌ 不支援 |
| Calico | ✅ 支援（且有額外的 GlobalNetworkPolicy） |
| Cilium | ✅ 支援（基於 eBPF，效能更佳） |
| Weave Net | ✅ 支援 |

Flannel 叢集建立 NetworkPolicy 物件不會報錯，但規則**不生效**。

---

## 二、選擇器語義完整解析

### 2.1 NetworkPolicy 作用於哪些 Pod（podSelector）

NetworkPolicy 用 `spec.podSelector` 決定這條規則**保護哪些 Pod**（被管理的 Pod）：

```yaml
spec:
  podSelector:
    matchLabels:
      app: backend      # 只保護有 app=backend label 的 Pod
```

```yaml
spec:
  podSelector: {}       # 空選擇器 = 選中此 namespace 中的所有 Pod
```

### 2.2 Ingress / Egress 方向

```
Ingress（入站）：誰可以發流量「進入」被保護的 Pod
Egress（出站）：被保護的 Pod 可以發流量「去往」哪裡

Pod A ──(Egress 規則管這條)──► Pod B ──(Ingress 規則管這條)──► Pod B 收到請求
                                         ↑
                              被 podSelector 選中的 Pod
```

```yaml
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress     # 聲明管理 Ingress（如不列出，有 ingress 規則時自動啟用）
  - Egress      # 聲明管理 Egress（必須明確列出才生效）
```

### 2.3 三種來源/目的地選擇器

#### podSelector — 按 Pod label 選

```yaml
ingress:
- from:
  - podSelector:
      matchLabels:
        role: frontend    # 允許 app=frontend 的 Pod 進入
                          # 僅限同一 namespace（跨 ns 需搭配 namespaceSelector）
```

#### namespaceSelector — 按 Namespace label 選

```yaml
ingress:
- from:
  - namespaceSelector:
      matchLabels:
        environment: prod  # 允許有 environment=prod label 的 namespace 中的所有 Pod
```

```bash
# 為 namespace 加上 label（才能被 namespaceSelector 選到）
kubectl label namespace monitoring environment=monitoring
```

#### ipBlock — 按 IP CIDR 選

```yaml
ingress:
- from:
  - ipBlock:
      cidr: 172.16.0.0/16    # 允許來自這個 CIDR 的流量
      except:
      - 172.16.1.0/24        # 但排除這個子網
```

### 2.4 AND vs OR：最常見的混淆點

**同一個 `from` 清單元素中的多個 selector → AND（同時滿足）**

```yaml
ingress:
- from:
  - podSelector:
      matchLabels:
        role: frontend
    namespaceSelector:         # 注意：同一個 "-" 下，沒有新的 "-"
      matchLabels:
        environment: prod
# 含義：Pod 必須同時滿足
#   1. 有 role=frontend label
#   2. 且在有 environment=prod label 的 namespace 中
# → AND 關係
```

**不同的 `from` 清單元素 → OR（滿足任一即可）**

```yaml
ingress:
- from:
  - podSelector:               # 第一個元素
      matchLabels:
        role: frontend
  - namespaceSelector:         # 第二個元素（新的 "-"）
      matchLabels:
        environment: prod
# 含義：
#   1. 有 role=frontend label 的 Pod（任何 namespace）
#   OR
#   2. 在有 environment=prod label 的 namespace 中的任何 Pod
# → OR 關係
```

**視覺對比：**

```
AND（同一個 map）：         OR（不同的 list item）：
- podSelector: A           - podSelector: A
  namespaceSelector: B     - namespaceSelector: B
  ↑ 同一個 map entry         ↑ 兩個獨立 list entry
```

### 2.5 ports 欄位

```yaml
ingress:
- from:
  - podSelector:
      matchLabels:
        role: frontend
  ports:
  - protocol: TCP
    port: 8080              # 只允許 TCP:8080
  - protocol: TCP
    port: 8443
  # 若 ports 欄位缺失 → 允許所有 port
  # 若 ports 指定 → 只允許列出的 port
```

---

## 三、四種 Default-Deny 模式

### 3.1 拒絕所有 Ingress（最常用）

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}    # 選中所有 Pod
  policyTypes:
  - Ingress          # 只管 Ingress，不影響 Egress
  # ingress: 欄位不存在 → 沒有任何允許規則 → 全部拒絕
```

```
效果：
  外部 → production 中任何 Pod   ❌
  其他 ns → production 中任何 Pod ❌
  production 中 Pod → 外部        ✅（Egress 未受管）
```

### 3.2 拒絕所有 Egress

```yaml
spec:
  podSelector: {}
  policyTypes:
  - Egress
  # egress: 欄位不存在 → 全部出站拒絕
```

**注意：** 拒絕所有 Egress 後，DNS 查詢（UDP/TCP 53 → CoreDNS）也會被阻斷，Pod 無法解析 Service 名稱。通常需要加上 DNS 白名單：

```yaml
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53              # 允許 DNS 查詢
```

### 3.3 同時拒絕 Ingress + Egress

```yaml
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  # 兩個 policyTypes 都不設規則 → 完全隔離
```

### 3.4 允許所有 Ingress（解除限制）

```yaml
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - {}                      # 空規則 = 允許所有來源的所有 port
```

---

## 四、NetworkPolicy 疊加行為

一個 Pod 可以同時被**多條** NetworkPolicy 選中，規則取**聯集（OR）**：

```
Pod backend 被以下 NP 選中：
  NP-1：允許來自 frontend Pod 的 :8080
  NP-2：允許來自 monitoring namespace 的 :8080

結果：
  frontend Pod → backend:8080     ✅  （NP-1 允許）
  monitoring Pod → backend:8080   ✅  （NP-2 允許）
  other Pod → backend:8080        ❌  （無任何 NP 允許）
  frontend Pod → backend:9090     ❌  （兩條 NP 都只允許 8080）
```

**不存在「拒絕規則」的概念**：NetworkPolicy 只有**允許規則**，沒有明確拒絕。邏輯是：
- Pod 未被任何 NP 的 podSelector 選中 → 完全不受限（允許所有）
- Pod 被至少一條 NP 選中 → 只有被規則明確允許的流量才通過

---

## 五、CNI 如何實作 NetworkPolicy

### 5.1 iptables 實作（Calico 預設）

Calico 將 NetworkPolicy 轉換為 iptables 規則（與 kube-proxy 類似的機制）：

```
封包進入 Node → iptables FORWARD chain
  → cali-FORWARD → cali-from-hep-forward
    → 查詢 ipset（Pod IP 集合）
    → 比對 NetworkPolicy 規則
    → ACCEPT 或 DROP
```

```bash
# 在有 Calico 的 Node 上查看生成的 iptables 規則
iptables -L -n | grep cali
# Chain cali-FORWARD (1 references)
# Chain cali-fw-caliXXXXXX (pod 的 veth 介面)
# ...
```

### 5.2 eBPF 實作（Cilium）

Cilium 使用 eBPF 在 kernel 層攔截封包，效能優於 iptables：

```
封包 → kernel 網路棧
  → eBPF hook（XDP 或 tc ingress/egress）
  → 查詢 Cilium BPF map（NetworkPolicy 規則存入 BPF map）
  → 允許 / 丟棄（在 kernel 內完成，不進 iptables）
```

優勢：
- 規則更新不需要重建整張 iptables（O(1) 查詢 BPF map vs O(n) iptables 遍歷）
- 支援 L7 策略（HTTP path、gRPC method）

---

## 六、NetworkPolicy 完整範例：前後端隔離

```yaml
# 場景：
#   frontend Pod (app=frontend) → backend Pod (app=backend) :8080
#   backend Pod → database Pod (app=db) :5432
#   其他全部拒絕

---
# 1. backend 只接受來自 frontend 的 :8080
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080

---
# 2. database 只接受來自 backend 的 :5432
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 5432

---
# 3. default-deny：其他所有 Pod 的 Ingress 全部拒絕
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

---

## 七、NetworkPolicy 問題排查指引

```
問題：Pod 無法連線到另一個 Pod / Service

排查步驟：
1. 確認 CNI 是否支援 NetworkPolicy
   kubectl get pods -n kube-system | grep -E "calico|cilium|weave"
   # 若只有 flannel → NetworkPolicy 不生效

2. 列出影響目標 Pod 的所有 NetworkPolicy
   kubectl get networkpolicy -n <namespace>
   kubectl describe networkpolicy <name> -n <namespace>

3. 確認 Pod labels（是否被 podSelector 選中）
   kubectl get pod <pod-name> --show-labels

4. 測試連線（在來源 Pod 內）
   kubectl exec -it <source-pod> -- curl -m 3 <target-ip>:<port>
   kubectl exec -it <source-pod> -- nc -zv <target-ip> <port>
```

| 症狀 | 根本原因 | 解法 |
|---|---|---|
| NetworkPolicy 建立但沒有效果 | CNI 不支援（如 Flannel） | 換用 Calico / Cilium |
| 允許特定 Pod 但流量仍被擋 | 同時有 default-deny NP + 允許規則 AND 條件不符 | 確認 label 完全一致 |
| 允許 Egress 但 DNS 不通 | 沒有放行 UDP/TCP 53 | 加上 DNS egress 規則 |
| 跨 namespace 流量被擋 | 只用 podSelector（預設限同 ns） | 加上 namespaceSelector |
| 部分 Port 通，部分不通 | ports 欄位只列了部分 port | 新增 port 到規則中 |

---

# Service、Ingress 與 Gateway API 原理

本章從 Service 四種類型出發，說明流量如何從外部世界進入叢集，並介紹 Ingress 與 Gateway API 的架構差異。

---

## 一、Service 四種類型完整說明

### 1.1 為什麼需要 Service？

Pod IP 是不穩定的：Pod 重啟、滾動更新、重新排程後 IP 都會改變。Service 提供一個**穩定的虛擬端點**，將流量分發到後端 Pod：

```
客戶端
  │ 存取 Service（固定 IP/DNS）
  ▼
Service（穩定）
  ├── Pod A（10.244.1.2）  ← 可能隨時消失重建
  ├── Pod B（10.244.2.3）
  └── Pod C（10.244.3.4）
```

Service 透過 **label selector** 動態追蹤後端 Pod，Endpoint Controller 維護最新的 Pod IP 清單（Endpoints 物件）。

### 1.2 ClusterIP（預設）

**用途：** 叢集內部服務間通訊。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  type: ClusterIP          # 預設，可省略
  selector:
    app: backend
  ports:
  - port: 80               # Service 暴露的 port
    targetPort: 8080       # 後端 Pod 的 port
    protocol: TCP
```

```
叢集內部               kube-proxy（iptables）
  curl backend-svc:80
    │ DNS → ClusterIP 10.96.1.5
    │
    ▼
  DNAT: 10.96.1.5:80 → 隨機選一個 Pod IP:8080
    │
    ▼
  Pod（10.244.x.x:8080）
```

- ClusterIP 是**虛擬 IP**，不綁定任何網路介面，只存在於 iptables DNAT 規則
- 叢集外部無法直接存取

### 1.3 NodePort

**用途：** 在每個 Node 上開放固定 port，允許外部直接存取。

```yaml
spec:
  type: NodePort
  selector:
    app: backend
  ports:
  - port: 80               # ClusterIP port（叢集內部用）
    targetPort: 8080       # Pod port
    nodePort: 30080        # Node 上開放的 port（30000-32767）
    # nodePort 不指定則自動分配
```

```
外部客戶端
  │ curl 192.168.56.11:30080（任意 Node IP）
  ▼
Node iptables PREROUTING
  DNAT: NodeIP:30080 → ClusterIP:80 → Pod:8080
  SNAT: 來源 IP 改為 Node IP（確保回程路由正確）
```

**缺點：**
- port 範圍受限（30000–32767）
- 每個 Service 佔用所有 Node 的同一個 port
- 生產環境通常不直接暴露 NodePort，而是放在 LoadBalancer 或 Ingress 後面

### 1.4 LoadBalancer

**用途：** 在雲端環境中，自動建立外部 Load Balancer（如 AWS ALB/NLB、GCP CLB）。

```yaml
spec:
  type: LoadBalancer
  selector:
    app: frontend
  ports:
  - port: 443
    targetPort: 8443
```

**運作流程：**

```
kubectl apply Service (type=LoadBalancer)
    │
    ▼
Cloud Controller Manager（CCM）監聽到新 Service
    │  呼叫雲端 API（AWS / GCP / Azure）
    ▼
建立外部 Load Balancer（有公網 IP）
    │
    ▼
Service 的 status.loadBalancer.ingress 填入公網 IP
    │
kubectl get svc → EXTERNAL-IP: 1.2.3.4

流量路徑：
Internet → 公網 IP（Load Balancer）→ Node:NodePort → Pod
```

**本地/裸機環境的替代方案：**

雲端以外的環境沒有 CCM，LoadBalancer Service 會永遠停在 `<pending>`。替代方案：
- **MetalLB**：為裸機環境提供 LoadBalancer 實作（ARP / BGP 模式）
- **kube-vip**：使用 VIP 提供 HA 控制面和 LoadBalancer 功能

```bash
# 安裝 MetalLB（裸機 LoadBalancer）
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

# 設定 IP 池
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.56.200-192.168.56.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
EOF
```

### 1.5 ExternalName

**用途：** 將 Service 名稱對應到**外部 DNS 名稱**（CNAME），不做 L4 代理。

```yaml
spec:
  type: ExternalName
  externalName: my-database.prod.example.com
  # 不需要 selector
```

```
Pod 內部：
  curl db-service:5432
    │ DNS 查詢 db-service.default.svc.cluster.local
    │ CoreDNS 回傳 CNAME → my-database.prod.example.com
    │ 再解析外部 DNS → 真實 IP
    ▼
外部資料庫（my-database.prod.example.com）
```

**典型用途：**
- 遷移期間：叢集內服務先指向外部舊系統，遷移完成後只改 ExternalName，不動 Pod 設定
- 跨叢集存取：叢集 A 的 Service 指向叢集 B 的外部 DNS

### 1.6 Headless Service（無頭服務）

**用途：** 不分配 ClusterIP，DNS 直接回傳所有 Pod IP，讓客戶端自行決定連接哪個 Pod。

```yaml
spec:
  clusterIP: None          # ← 關鍵：設為 None
  selector:
    app: mysql
  ports:
  - port: 3306
```

**DNS 行為差異：**

```
普通 Service（ClusterIP）：
  DNS 查詢 mysql-svc.default.svc.cluster.local
  → 回傳 ClusterIP（單一 IP）
  → 由 iptables 做負載均衡

Headless Service：
  DNS 查詢 mysql-svc.default.svc.cluster.local
  → 回傳所有 Pod IP（多筆 A record）
  → 客戶端自行選擇

StatefulSet 的 Headless Service 還提供 Pod DNS：
  mysql-0.mysql-svc.default.svc.cluster.local → mysql-0 的 Pod IP
  mysql-1.mysql-svc.default.svc.cluster.local → mysql-1 的 Pod IP
  （穩定的 Pod DNS，即使 Pod IP 改變也不影響）
```

**StatefulSet 必須搭配 Headless Service 的原因：**

```
mysql-0 是 Primary，mysql-1/2 是 Replica
  → Replica 需要連接「特定的」Primary（mysql-0），不能 load balance
  → 必須有 mysql-0.mysql-svc 這樣的穩定 DNS
  → 需要 Headless Service 提供 Pod 個別 DNS
```

### 1.7 四種 Service 類型總覽

```
ClusterIP（叢集內部）
  Pod ──► Service（虛擬 IP）──► Pod
  特性：僅叢集內可達，iptables DNAT 負載均衡

NodePort（Node 端口暴露）
  外部 ──► Node:30080 ──► ClusterIP ──► Pod
  特性：所有 Node 開放同一端口，適合測試

LoadBalancer（雲端整合）
  Internet ──► 公網 LB ──► Node:NodePort ──► Pod
  特性：需要 CCM，裸機用 MetalLB

ExternalName（DNS 代理）
  Pod ──► CoreDNS CNAME ──► 外部 DNS ──► 外部服務
  特性：無 ClusterIP，無 iptables，純 DNS

Headless（直接 Pod DNS）
  Pod ──► DNS（全部 Pod IP）──► 選定 Pod
  特性：clusterIP=None，StatefulSet 專用穩定 DNS
```

---

## 二、Ingress 原理

### 2.1 Ingress 解決的問題

NodePort 和 LoadBalancer 的限制：

```
問題：每個 Service 都需要一個獨立的 LoadBalancer（昂貴）或 NodePort（端口數量有限）

Service A ──► LoadBalancer（公網 IP 1）
Service B ──► LoadBalancer（公網 IP 2）
Service C ──► LoadBalancer（公網 IP 3）
```

Ingress 用**一個** LoadBalancer 入口，根據 HTTP Host / Path 路由到不同 Service：

```
Internet
  │ 單一入口（80/443）
  ▼
Ingress Controller（nginx / traefik / ...）
  ├── host: api.example.com     → Service: api-svc:8080
  ├── host: www.example.com
  │     path: /shop             → Service: shop-svc:3000
  │     path: /blog             → Service: blog-svc:4000
  └── TLS 終止（HTTPS → HTTP）
```

### 2.2 Ingress 的兩個組成部分

**1. IngressClass + Ingress Controller（實際執行流量轉發的程式）**

Ingress Controller 不是 K8s 內建元件，需要額外安裝：

```bash
# 安裝 nginx Ingress Controller（以 NodePort 方式暴露）
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml
```

**2. Ingress 物件（路由規則宣告）**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /   # Controller 特定設定
spec:
  ingressClassName: nginx           # 指定使用哪個 IngressClass
  tls:
  - hosts:
    - api.example.com
    secretName: api-tls-secret      # TLS 憑證（Secret 類型 kubernetes.io/tls）
  rules:
  - host: api.example.com           # 根據 Host header 路由
    http:
      paths:
      - path: /v1
        pathType: Prefix            # Prefix / Exact / ImplementationSpecific
        backend:
          service:
            name: api-v1-svc
            port:
              number: 8080
      - path: /v2
        pathType: Prefix
        backend:
          service:
            name: api-v2-svc
            port:
              number: 8080
  - host: www.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-svc
            port:
              number: 80
```

### 2.3 pathType 三種模式

| pathType | 行為 | 範例 |
|---|---|---|
| `Exact` | 完全匹配，區分大小寫 | `/foo` 只匹配 `/foo` |
| `Prefix` | 前綴匹配（以 `/` 分隔） | `/foo` 匹配 `/foo`, `/foo/bar`，但不匹配 `/foobar` |
| `ImplementationSpecific` | 由 IngressClass 的 Controller 決定 | nginx 支援正規表示式 |

### 2.4 IngressClass 與多 Controller 共存

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"   # 設為預設
spec:
  controller: k8s.io/ingress-nginx

---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik
spec:
  controller: traefik.io/ingress-controller
```

同一叢集可以有多個 Ingress Controller，Ingress 物件透過 `ingressClassName` 指定使用哪個：

```
IngressClass: nginx    ←──── Ingress A (ingressClassName: nginx)
IngressClass: traefik  ←──── Ingress B (ingressClassName: traefik)
```

### 2.5 TLS 終止

```bash
# 建立自簽憑證
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=api.example.com/O=example"

# 建立 TLS Secret
kubectl create secret tls api-tls-secret \
  --cert=tls.crt --key=tls.key
```

```
HTTPS 流量路徑：
  客戶端 ──HTTPS──► Ingress Controller（TLS 終止）──HTTP──► Service ──► Pod
                    （nginx 解密，轉為明文 HTTP）
```

若需要 End-to-End TLS（不終止），nginx 支援 `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` annotation。

### 2.6 Ingress Controller 架構圖

```
叢集外部
  │ HTTP/HTTPS :80/:443
  ▼
LoadBalancer Service（或 NodePort）
  │
  ▼
Ingress Controller Pod（nginx）
  │ 監聽 Ingress 物件變化
  │ 動態更新 nginx.conf
  ├──► Service A → Endpoints（Pod IP:Port）
  ├──► Service B → Endpoints（Pod IP:Port）
  └──► Service C → Endpoints（Pod IP:Port）

Ingress Controller 直接轉發到 Pod IP（繞過 ClusterIP iptables）
→ 減少一層 DNAT，效能更好
```

---

## 三、Gateway API

### 3.1 Ingress 的局限

Ingress API 設計於 2015 年，存在幾個根本限制：

| 問題 | 說明 |
|---|---|
| **表達能力不足** | 只支援 HTTP Host/Path，TCP/UDP 路由需要非標準 annotation |
| **annotation 地獄** | 進階功能（逾時、重試、流量鏡射）靠 Controller 特定 annotation，不可移植 |
| **角色混用** | 基礎設施管理員和應用開發者共用同一個 Ingress 物件 |
| **跨 namespace 路由困難** | 一個 Ingress 物件難以跨 namespace 管理後端 Service |

### 3.2 Gateway API 三層模型

Gateway API 引入角色分離：

```
叢集管理員                    平台工程師                 應用開發者
     │                            │                          │
     ▼                            ▼                          ▼
GatewayClass               Gateway                    HTTPRoute / TCPRoute
（Controller 類型）          （實際的 LB 實例）           （路由規則）

apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx-gateway
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller

---
kind: Gateway
metadata:
  name: prod-gateway
  namespace: infra
spec:
  gatewayClassName: nginx-gateway
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      certificateRefs:
      - name: prod-tls

---
kind: HTTPRoute
metadata:
  name: api-route
  namespace: app              # 可在不同 namespace
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra          # 跨 namespace 引用 Gateway
  hostnames: ["api.example.com"]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1
    backendRefs:
    - name: api-v1-svc
      port: 8080
      weight: 90             # 流量權重（金絲雀發布）
    - name: api-v1-canary
      port: 8080
      weight: 10
```

### 3.3 Ingress vs Gateway API 對比

| 維度 | Ingress | Gateway API |
|---|---|---|
| API 成熟度 | GA（v1） | GA（v1，K8s 1.31+） |
| 協議支援 | HTTP/HTTPS | HTTP, HTTPS, TCP, UDP, TLS, gRPC |
| 流量管理 | 基本 path/host | 重試、逾時、流量分割、鏡射（標準化） |
| 角色分離 | 無（一個物件） | GatewayClass / Gateway / Route 三層 |
| 跨 namespace | 困難 | 原生支援（ReferenceGrant 控制） |
| 金絲雀發布 | 靠 annotation（不可移植） | 原生 weight 支援 |
| 現有生態 | nginx、traefik、HAProxy... | nginx、Istio、Envoy Gateway、Cilium... |

### 3.4 現階段建議

```
新專案        ─────────────────────────────────► Gateway API（未來主流）
現有專案       ─── 繼續用 Ingress，等生態成熟後遷移
CKA/CKAD 考試 ─── 目前仍以 Ingress 為主（Gateway API 尚未列入考綱）
```

---

## 四、Service / Ingress 問題排查指引

### 4.1 Service 無法連線

```
問題：curl ClusterIP:Port 無回應

排查步驟：
1. 確認 Endpoints 是否有 Pod IP
   kubectl get endpoints <svc-name>
   # 若 ENDPOINTS 為 <none>：selector 不符，或 Pod 未 Ready

2. 確認 Pod label 與 Service selector 一致
   kubectl get pod --show-labels
   kubectl get svc <svc-name> -o jsonpath='{.spec.selector}'

3. 確認 Pod 的 targetPort 與 containerPort 一致
   kubectl describe pod <pod-name> | grep Port

4. 從另一個 Pod 內測試
   kubectl run test --image=busybox --rm -it -- wget -O- http://<svc-name>:<port>

5. 確認 kube-proxy 是否正常
   kubectl get pods -n kube-system | grep kube-proxy
   kubectl logs -n kube-system <kube-proxy-pod>
```

### 4.2 Ingress 無法路由

```
問題：外部存取 Ingress URL 收到 404 或 Connection Refused

排查步驟：
1. 確認 Ingress Controller 是否運行
   kubectl get pods -n ingress-nginx

2. 確認 Ingress 物件的 ADDRESS 欄位
   kubectl get ingress
   # ADDRESS 為空 → Controller 未就緒或 LoadBalancer pending

3. 確認 IngressClass 設定正確
   kubectl get ingressclass
   kubectl describe ingress <name> | grep IngressClass

4. 確認後端 Service 和 Endpoints 正常
   kubectl get svc,endpoints <backend-svc>

5. 查看 Controller 日誌
   kubectl logs -n ingress-nginx <controller-pod> | tail -50
```

### 4.3 常見錯誤對照

| 症狀 | 根本原因 | 解法 |
|---|---|---|
| `kubectl get endpoints` 顯示 `<none>` | selector 不符 Pod label | 對齊 selector 與 Pod label |
| Service 可達但特定 Pod 回錯誤 | targetPort 與 containerPort 不符 | 確認 port 設定 |
| LoadBalancer `EXTERNAL-IP` 一直 `<pending>` | 無 CCM 或 MetalLB | 裸機環境安裝 MetalLB |
| Ingress 回 `404 Not Found`（nginx） | path 不匹配或 rewrite-target 設定錯誤 | 確認 pathType 和 path 設定 |
| Ingress 回 `503 Service Unavailable` | 後端 Service 無可用 Endpoints | 檢查 Pod 健康狀態 |
| Ingress TLS 憑證警告 | Secret 憑證過期或 CN 不符 | 重建 TLS Secret |
| Headless Service DNS 只回一個 IP | 客戶端 DNS 快取 | 使用 `nslookup` 確認，設定 `ndots` |

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
