# 使用 kubeadm 安裝 Kubernetes 叢集（Ubuntu 24.04 Server）

本指南說明如何在 Ubuntu 24.04 LTS Server 上，使用 kubeadm 建立三節點 Kubernetes 叢集。

提供兩種安裝方式：
- **方法一：Vagrant 自動化安裝**（推薦，適合本地開發測試）
- **方法二：手動逐步安裝**（適合正式環境或學習每個步驟）

若目標是正式環境，請先閱讀「[安裝前需求收集與分析](#安裝前需求收集與分析)」章節，確定 Pod/Service CIDR、Control Plane Endpoint、CNI 等**事後無法變更**的決策後再開始安裝。

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

## 安裝前需求收集與分析

kubeadm 的許多參數（Pod CIDR、Service CIDR、Control Plane Endpoint、CRI、cgroup driver 等）在 `kubeadm init` 之後**極難或無法變更**，改錯了幾乎等同重建叢集。因此在動手之前，應先系統性地收集需求、做出決策，再把決策轉成安裝參數。

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  1. 需求收集  │ ─► │  2. 需求分析  │ ─► │  3. 安裝決策表 │ ─► │  4. 執行安裝  │
│  訪談 / 問卷  │    │  容量、HA、   │    │  kubeadm-     │    │  方法一 / 二  │
│              │    │  網路、安全   │    │  config.yaml  │    │              │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

本章先列出**該問哪些問題**，再逐項說明**如何分析**與**對應的安裝決策**，最後提供本指南範例環境的完整決策表與可複製的需求收集範本。

---

### 一、需求收集清單

在與使用單位（開發團隊、營運團隊、資安團隊）訪談時，至少要釐清以下面向。右欄標示每個問題會影響哪個安裝決策，方便回頭對照。

| 面向 | 要釐清的問題 | 影響的安裝決策 |
|------|-------------|---------------|
| **用途** | 學習測試？開發環境？正式營運？邊緣節點？ | HA 架構、CNI、儲存、安全強度 |
| **工作負載** | 跑什麼應用？無狀態 Web？資料庫？批次運算？AI/GPU？ | 節點規格、儲存類型、Device Plugin |
| **規模** | 預估 Pod 數量、節點數量、未來 1–2 年成長幅度？ | Pod/Service CIDR 大小、節點 sizing |
| **可用性** | 可接受的停機時間（SLA）？Control Plane 掛掉能否接受？ | 單一 vs 多 Control Plane、etcd 拓撲 |
| **網路** | 既有內網網段？VPN 網段？是否有多個叢集需互通？需要 NetworkPolicy 嗎？ | Pod/Service CIDR、CNI 選型 |
| **對外服務** | 如何讓外部流量進入？有硬體 LB 或雲端 LB 嗎？ | NodePort / MetalLB / Ingress / Gateway |
| **儲存** | 需要持久化資料嗎？多 Pod 共享讀寫（RWX）？快照/備份？ | StorageClass、CSI driver |
| **安全合規** | 需符合哪些規範（CIS、ISO 27001、個資法）？稽核日誌保存多久？ | 稽核政策、加密、PodSecurity、RBAC |
| **身分驗證** | 使用者如何登入？有 AD / LDAP / OIDC 嗎？ | apiserver OIDC 參數、RBAC 設計 |
| **基礎環境** | 實體機、VM、還是雲端？OS 版本？是否可連外網？有 Proxy 嗎？ | 版本選型、映像檔來源、air-gap 準備 |
| **營運** | 誰負責維運？有既有監控/日誌系統嗎？升級與備份頻率？ | 監控堆疊、etcd 備份、升級策略 |

> **實務建議：** 把這張表印出來或做成共用文件，逐項填寫並記錄「決策者」與「決策日期」。日後爭議（例如「為什麼當初選 Flannel？」）時可以回溯。

---

### 二、用途與情境分析

不同用途對應完全不同的架構取捨。先確定叢集定位，後續的所有決策才有依據。

| 情境 | 特徵 | 建議架構 | 本指南對應 |
|------|------|---------|-----------|
| **學習 / 個人實驗** | 單人使用、可隨時重建、資源有限 | 1 master + 1–2 worker，Flannel，無持久儲存 | 方法一（Vagrant） |
| **團隊開發 / 測試** | 多人共用、需模擬正式環境行為、允許短暫停機 | 1 master + N worker，Calico（可測 NetworkPolicy），NFS 或 local PV | 方法二 + 調整 CNI |
| **正式營運（小型）** | 需 SLA、資料不可遺失 | 3 control plane（stacked etcd）+ N worker，Calico/Cilium，CSI 儲存，稽核與備份 | 方法二 + HA 章節參數 |
| **正式營運（大型）** | 數百節點以上、多租戶、多團隊 | 3–5 control plane + 外部 etcd，Cilium，多 StorageClass，OIDC，多叢集管理 | 超出本指南範圍 |
| **邊緣 / IoT** | 資源受限、網路不穩 | 考慮 k3s / k0s 而非 kubeadm | 超出本指南範圍 |

**判斷準則：**
- 若答案是「掛掉會有人打電話罵」→ 至少 3 個 Control Plane。
- 若答案是「資料掉了會出事」→ 必須規劃 etcd 備份與持久儲存，不能只用 `emptyDir`/`hostPath`。
- 若答案是「多個團隊共用」→ 需要 NetworkPolicy（排除 Flannel）、RBAC 分權、ResourceQuota。

---

### 三、規模與容量規劃

#### 3.1 kubeadm 官方最低需求

| 角色 | CPU | 記憶體 | 磁碟 | 說明 |
|------|-----|-------|------|------|
| Control Plane | 2 vCPU | 2 GB | 20 GB | 低於此值 `kubeadm init` 的 preflight check 會失敗（可用 `--ignore-preflight-errors` 略過，但不建議） |
| Worker | 1 vCPU | 1 GB | 20 GB | 實際需求取決於工作負載 |

這是「能跑起來」的下限，不是「能用」的建議值。

#### 3.2 Worker 節點 Sizing 公式

```
單一節點可用資源 = 節點總資源 − kube-reserved − system-reserved − eviction-threshold

所需 Worker 節點數 = ceil( Σ(所有 Pod requests) × 冗餘係數 / 單一節點可用資源 )
```

- **kube-reserved**：留給 kubelet、containerd、kube-proxy 等元件（建議 CPU 0.5–1 核、記憶體 1–2 GB）。
- **system-reserved**：留給 OS（sshd、journald 等，建議記憶體 0.5–1 GB）。
- **eviction-threshold**：kubelet 預設在可用記憶體 < 100Mi 時開始驅逐 Pod。
- **冗餘係數**：建議 1.3–1.5，確保任一節點故障時，其他節點仍能承接其 Pod（N+1）。

**範例計算：**

```
需求：20 個微服務，每個 3 副本，平均 request = 0.25 CPU / 512Mi
      → Σ requests = 60 Pod × 0.25 CPU = 15 CPU；60 × 512Mi = 30 GB

節點規格：4 vCPU / 16 GB
可用資源：CPU 4 − 1（reserved）= 3；記憶體 16 − 2（reserved）− 0.5（eviction）≈ 13.5 GB

所需節點：CPU：ceil(15 × 1.4 / 3) = 7；記憶體：ceil(30 × 1.4 / 13.5) = 4
→ 取較大者：7 台 Worker（CPU 是瓶頸，可考慮改用 8 vCPU 規格降至 4 台）
```

#### 3.3 Kubernetes 內建上限

規劃時不可超過以下數值（v1.32）：

| 項目 | 上限 | 備註 |
|------|------|------|
| 每節點 Pod 數 | 110（預設） | 可透過 kubelet `maxPods` 調整，但受 Pod CIDR 每節點子網大小限制 |
| 節點總數 | 5,000 | |
| Pod 總數 | 150,000 | |
| 容器總數 | 300,000 | |

#### 3.4 磁碟規劃

| 用途 | 建議 | 原因 |
|------|------|------|
| **etcd 資料目錄**（`/var/lib/etcd`） | SSD / NVMe，獨立磁碟 | etcd 對 fsync 延遲極敏感（p99 需 < 10ms），與容器映像共用磁碟會導致 leader 切換、apiserver 逾時 |
| **容器映像與 Layer**（`/var/lib/containerd`） | 依映像數量估算，至少 50 GB | 映像累積速度常超乎預期，建議設定 kubelet imageGC 門檻 |
| **日誌**（`/var/log/pods`） | 設定 `containerLogMaxSize` / `containerLogMaxFiles` | 預設 10Mi × 5 個檔案，高流量應用需調大或接外部日誌系統 |
| **臨時儲存**（`emptyDir`） | 依應用需求 | 計入節點 ephemeral-storage 配額 |

---

### 四、高可用性需求

#### 4.1 三種 Control Plane 拓撲

```
單一 Control Plane                Stacked etcd HA                  External etcd HA
（本指南範例）                     （小型正式環境）                   （大型正式環境）

┌────────────┐                  ┌──── LB / VIP ────┐              ┌──── LB / VIP ────┐
│ apiserver  │                  │                   │              │                   │
│ etcd       │              ┌───┴───┐ ┌───┴───┐ ┌───┴───┐      ┌───┴───┐ ┌───┴───┐ ┌───┴───┐
│ scheduler  │              │ api   │ │ api   │ │ api   │      │ api   │ │ api   │ │ api   │
│ ctrl-mgr   │              │ etcd  │ │ etcd  │ │ etcd  │      │ sched │ │ sched │ │ sched │
└────────────┘              └───────┘ └───────┘ └───────┘      └───┬───┘ └───┬───┘ └───┬───┘
                                                                   │         │         │
掛掉 = 叢集無法管理           掛掉 1 台仍可運作                  ┌───┴───┐ ┌───┴───┐ ┌───┴───┐
（既有 Pod 仍會跑）           最少 3 台（etcd quorum）            │ etcd  │ │ etcd  │ │ etcd  │
                                                               └───────┘ └───────┘ └───────┘
                                                               etcd 與 apiserver 故障域分離
                                                               最少 3 + 3 = 6 台
```

#### 4.2 etcd Quorum 與節點數

etcd 採用 Raft 共識，需要**過半數**節點存活才能寫入。節點數必須是**奇數**。

| etcd 節點數 | Quorum | 可容忍故障數 | 說明 |
|------------|--------|-------------|------|
| 1 | 1 | 0 | 學習/測試 |
| 3 | 2 | 1 | 正式環境最低建議 |
| 5 | 3 | 2 | 大型叢集；再多會增加寫入延遲 |
| 2 / 4 | 2 / 3 | 1 / 1 | **沒有意義**：容錯數與 1 / 3 台相同，反而多一個故障點 |

#### 4.3 必須在 `kubeadm init` 時決定的 HA 參數

> **關鍵：`--control-plane-endpoint`**
>
> 這個參數指定 apiserver 的「穩定位址」（DNS 名稱或 VIP），會被寫入 apiserver 憑證的 SAN、`admin.conf`、以及所有 Worker 的 `kubelet.conf`。
>
> - **未設定**（本指南範例）：Worker 直接連 `192.168.56.10:6443`，日後要加第二台 Control Plane 時，必須重簽憑證並逐一修改所有節點的 kubeconfig，非常麻煩。
> - **有設定**：即使目前只有一台 Control Plane，也可以先設定 `--control-plane-endpoint=k8s-api.example.com:6443`，DNS 先指向唯一那台；日後加 LB 只需改 DNS。
>
> **建議：只要有一絲可能未來要升級成 HA，就在 init 時設定 `--control-plane-endpoint`。** 成本幾乎為零。

HA 前端負載平衡器的選項：

| 方案 | 適用環境 | 說明 |
|------|---------|------|
| 雲端 LB（AWS NLB、GCP TCP LB） | 公有雲 | 最簡單，健康檢查打 `/healthz` |
| HAProxy + keepalived | 地端 / VM | keepalived 提供 VIP，HAProxy 做 TCP 6443 轉發 |
| kube-vip | 地端，不想額外裝機器 | 以 static Pod 形式跑在 Control Plane 上，同時提供 VIP 與 LB |

---

### 五、網路規劃

網路是**最不可逆**的決策，也是跨團隊衝突最多的地方（IP 網段通常由網路團隊管理）。

#### 5.1 三個互不重疊的網段

```
┌─────────────────────────────────────────────────────────────────┐
│  Node Network（實體/VM 網段）      例：192.168.56.0/24              │
│    └── 節點 IP、apiserver 位址、NodePort 對外位址                  │
│                                                                   │
│  Pod CIDR（--pod-network-cidr）    例：10.244.0.0/16               │
│    └── 每個 Pod 一個 IP；每節點切一個 /24 子網（預設）              │
│                                                                   │
│  Service CIDR（--service-cidr）    例：10.96.0.0/12（預設）         │
│    └── ClusterIP 虛擬 IP，只存在於 iptables/IPVS 規則中             │
└─────────────────────────────────────────────────────────────────┘
```

**三者必須互不重疊，且不可與以下網段重疊：**
- 企業內網（辦公室、資料中心）既有網段
- VPN 用戶端網段
- 其他 Kubernetes 叢集的 Pod/Service CIDR（若日後需跨叢集互通）
- 雲端 VPC 的 CIDR
- Docker 預設的 `172.17.0.0/16`（若節點上同時跑 Docker）

> **常見災難：** Pod CIDR 用了 `10.0.0.0/16`，結果公司 VPN 也是 `10.0.x.x`——Pod 永遠連不到內部資料庫，而且問題只在 VPN 使用者身上出現，極難排查。

#### 5.2 Pod CIDR 大小計算

kube-controller-manager 會從 Pod CIDR 為每個節點切出一個子網（`--node-cidr-mask-size`，IPv4 預設 `/24`）。

```
Pod CIDR /16  ÷  每節點 /24  =  2^(24−16) = 256 個節點
每節點 /24    =  254 個可用 IP（> 預設 maxPods 110，足夠）

若需 1,000 個節點：Pod CIDR 至少 /14（2^10 = 1,024 個 /24）
若每節點只需 50 Pod：可將 node-cidr-mask-size 設為 /26（62 IP），同樣的 /16 可支援 1,024 節點
```

決策時考慮**未來 2 年的最大節點數**，並留 2 倍餘裕。

#### 5.3 CNI 選型決策

| 需求 | Flannel | Calico | Cilium |
|------|:-------:|:------:|:------:|
| 安裝簡單、學習用 | ✅ | ✅ | ⚠️ 較複雜 |
| NetworkPolicy 強制執行 | ❌ 不支援 | ✅ | ✅ |
| L7 Policy（HTTP path / method） | ❌ | ❌ | ✅ |
| 不封裝（BGP / 原生路由，效能較好） | ❌ | ✅ | ✅ |
| 取代 kube-proxy（eBPF） | ❌ | ⚠️ 部分 | ✅ |
| 可觀測性（流量圖、Hubble） | ❌ | ⚠️ 需 Enterprise | ✅ |
| 傳輸加密（WireGuard / IPsec） | ❌ | ✅ | ✅ |
| 多租戶正式環境 | ❌ | ✅ | ✅ |
| 核心版本需求 | 低 | 低 | ≥ 5.10 建議 |

**決策準則：**
- 只是學習或 CKA 練習 → **Flannel**（本指南）。
- 需要 NetworkPolicy 但團隊對 eBPF 不熟 → **Calico**。
- 正式環境、重視效能與可觀測性、核心夠新 → **Cilium**。

#### 5.4 封裝模式與 MTU

VXLAN 封裝會在每個封包加上 50 bytes 標頭。實體 MTU 1500 時，Pod 介面 MTU 需降為 **1450**（Flannel 自動處理）。若底層網路已是 VXLAN（例如 OpenStack、某些雲端 VPC），會造成**雙重封裝**，MTU 需再減 50，否則出現「小封包正常、大檔案傳輸卡住」的詭異問題。

規劃時確認：
- 實體網路 MTU（是否支援 Jumbo Frame 9000？可大幅降低封裝損耗）
- 底層是否已有 overlay
- 若節點都在同一 L2 網段，可考慮 Calico/Cilium 的原生路由模式，完全避免封裝

#### 5.5 多網卡與介面選擇

VM 環境（Vagrant、VMware、OpenStack）常有多張網卡。本指南的 Vagrant 節點就有兩張：

| 介面 | 位址 | 用途 | 問題 |
|------|------|------|------|
| `eth0` | 10.0.2.15（NAT） | 連外網 | **所有 VM 都是同一個 IP**，若 kubelet 或 Flannel 誤選此介面，節點間完全無法通訊 |
| `eth1` | 192.168.56.x（Host-only） | 節點互通 | 正確的叢集介面 |

需事先決定並在安裝時明確指定：
- `kubeadm init --apiserver-advertise-address=<eth1 IP>`
- kubelet `--node-ip=<eth1 IP>`（見「五、修正節點 Internal IP」）
- Flannel `--iface=eth1`（見「三、部署 Pod 網路」）

#### 5.6 對外流量入口

| 方案 | 適用 | 限制 |
|------|------|------|
| NodePort | 測試 | 埠號 30000–32767，需自行在前面放 LB |
| 雲端 LoadBalancer | 公有雲 | 每個 Service 一個 LB，費用高 |
| MetalLB | 地端 | 需保留一段 Node Network 內的 IP 池給它（例：192.168.56.200–250） |
| Ingress Controller（nginx / traefik） | HTTP/HTTPS | 需搭配上述之一提供入口 IP |
| Gateway API | 新專案 | Ingress 的後繼者，需 CNI 或 Controller 支援 |

**需向網路團隊申請：** MetalLB 的 IP 池、Ingress 的 DNS 名稱與 TLS 憑證來源。

#### 5.7 節點間必須開放的連接埠

安裝前提交給防火牆 / 雲端 Security Group 管理者：

| 方向 | 協定 / 埠 | 用途 | 使用者 |
|------|----------|------|--------|
| Control Plane 入站 | TCP 6443 | kube-apiserver | 所有節點、kubectl 使用者 |
| Control Plane 入站 | TCP 2379–2380 | etcd client / peer | apiserver、其他 etcd |
| Control Plane 入站 | TCP 10250 | kubelet API | apiserver（logs / exec） |
| Control Plane 入站 | TCP 10257 | kube-controller-manager | 本機 |
| Control Plane 入站 | TCP 10259 | kube-scheduler | 本機 |
| Worker 入站 | TCP 10250 | kubelet API | apiserver |
| Worker 入站 | TCP 10256 | kube-proxy 健康檢查 | LB |
| Worker 入站 | TCP 30000–32767 | NodePort Service | 外部使用者 |
| 所有節點互通 | UDP 8472 | Flannel / Cilium VXLAN | 所有節點 |
| 所有節點互通 | UDP 4789 | Calico VXLAN | 所有節點 |
| 所有節點互通 | TCP 179 | Calico BGP | 所有節點 |

本指南在測試環境直接關閉 UFW；正式環境應只開放上表。

#### 5.8 DNS 與主機名稱

- 每個節點需有**唯一**的 hostname、MAC address、`/sys/class/dmi/id/product_uuid`（VM 複製時常重複，kubeadm 會報錯）。
- 節點需能互相解析 hostname（`/etc/hosts` 或內部 DNS）。
- 決定叢集內部 DNS 網域（預設 `cluster.local`，若多叢集需互通建議改為 `<cluster-name>.local`，**init 後不可變更**）。

#### 5.9 網際網路存取與 Proxy

| 情境 | 需準備 |
|------|--------|
| 可直接連外 | 無 |
| 需經 Proxy | containerd 的 `HTTP_PROXY` / `NO_PROXY`（**NO_PROXY 必須包含 Node、Pod、Service 三個 CIDR**，否則 apiserver 流量被送到 Proxy） |
| 完全離線（air-gap） | 私有 registry（Harbor）、預先 `kubeadm config images pull` 並推送、apt 套件鏡像、Flannel/CNI 映像 |

---

### 六、儲存需求

#### 6.1 需求釐清

| 問題 | 若答「是」的影響 |
|------|----------------|
| 有需要持久化的資料嗎（資料庫、上傳檔案）？ | 需要 PV/PVC 與 StorageClass，不能只靠 `emptyDir` |
| 多個 Pod 需同時讀寫同一份資料（RWX）嗎？ | 排除 block storage（iSCSI、雲端磁碟），需 NFS / CephFS / 物件儲存 |
| 需要快照、複製、災難復原嗎？ | 需支援 CSI Snapshot 的 driver |
| 資料庫需要多少 IOPS？ | 決定 SSD vs HDD、本地 vs 網路儲存 |
| 資料是否需要跨可用區複製？ | 雲端需選 regional disk；地端需 Ceph / Longhorn 多副本 |

#### 6.2 儲存方案決策表

| 方案 | 存取模式 | 適用 | 需事先準備 |
|------|---------|------|-----------|
| `hostPath` / `local` PV | RWO | 學習、單節點測試 | 無；但 Pod 綁死在特定節點 |
| NFS（`nfs-subdir-external-provisioner`） | RWX | 開發環境、小型正式 | NFS 伺服器、所有節點裝 `nfs-common` |
| Longhorn / OpenEBS | RWO（Longhorn 可 RWX） | 地端正式，無外部儲存設備 | 每節點額外磁碟、`open-iscsi` |
| Rook-Ceph | RWO / RWX / Object | 地端大型正式 | ≥ 3 節點各一顆裸磁碟、足夠記憶體（每 OSD 4 GB） |
| 雲端 CSI（EBS / PD / Azure Disk） | RWO | 公有雲 | IAM 權限、CSI driver |
| 企業儲存 CSI（NetApp Trident、Pure、Dell） | 依設備 | 已有 SAN/NAS | 廠商 CSI driver、儲存端帳號 |

> 詳細原理見後方「存儲原理深度說明」章節。此處只需在安裝前決定**要不要**、**用哪一種**、**誰提供後端**。

---

### 七、安全與合規需求

安全需求中有幾項**必須在 `kubeadm init` 時透過設定檔啟用**，事後補加需要修改 apiserver static Pod manifest，較為麻煩。

| 需求 | 實作機制 | 是否需在 init 時決定 | 說明 |
|------|---------|:------------------:|------|
| **稽核日誌**（誰在何時做了什麼） | apiserver `--audit-policy-file` / `--audit-log-path` | ✅ 建議 | 合規要求（ISO 27001、金融業）幾乎必備；需規劃日誌保留天數與磁碟空間 |
| **Secret 靜態加密** | `EncryptionConfiguration` + `--encryption-provider-config` | ✅ 建議 | 未加密時任何能讀 etcd 的人都能看到所有 Secret 明文 |
| **NetworkPolicy** | CNI 支援 | ✅（CNI 選型） | Flannel 不支援，需 Calico / Cilium |
| **Pod Security Admission** | Namespace label（`pod-security.kubernetes.io/enforce`） | ❌ | 可事後啟用；建議正式環境至少 `baseline`，敏感 Namespace 用 `restricted` |
| **RBAC 分權** | Role / ClusterRole / RoleBinding | ❌ | kubeadm 預設啟用 RBAC；需規劃團隊 → Namespace → 角色對應表 |
| **使用者身分驗證** | apiserver `--oidc-issuer-url` 等 | ✅ 建議 | 對接 Keycloak / Azure AD / Google，避免分發 admin.conf |
| **憑證輪替** | kubeadm 自動核發 1 年憑證、CA 10 年 | ❌ | 需規劃每年 `kubeadm certs renew` 或啟用 kubelet 自動輪替（預設開啟） |
| **CIS Benchmark** | kube-bench 掃描 | ❌ | 見後方 CKS 章節；安裝後執行並修正 FAIL 項目 |
| **映像檔安全** | 私有 registry、映像掃描、簽章驗證（cosign） | ❌ | 需決定是否禁止拉取 Docker Hub 公開映像 |
| **etcd 存取控制** | etcd 只監聽 Control Plane 內部介面 | ❌ | kubeadm 預設已做；確認防火牆不對外開 2379 |

**合規需求對照：**

| 規範 | 通常要求的項目 |
|------|--------------|
| CIS Kubernetes Benchmark | 稽核、加密、RBAC、Pod Security、kubelet 認證 |
| ISO 27001 / SOC 2 | 稽核日誌保存 ≥ 1 年、存取控制、變更紀錄 |
| 個資法 / GDPR | Secret 加密、資料所在地、刪除機制 |
| PCI DSS | 網路隔離（NetworkPolicy）、加密傳輸、稽核 |

---

### 八、版本選型與相容性

#### 8.1 Kubernetes 版本策略

- Kubernetes 每年釋出 **3 個 minor 版本**，每個版本支援約 **14 個月**。
- 同一時間只有**最新 3 個 minor 版本**受支援。安裝時選最新版減一（例如最新是 1.33，選 1.32）通常最穩：問題已被踩過、又不會太快 EOL。
- **升級只能一次一個 minor 版本**（1.30 → 1.31 → 1.32），不能跳版。若選了太舊的版本，日後追版本會很痛苦。

#### 8.2 元件版本偏差規則（Version Skew Policy）

| 元件 | 相對於 kube-apiserver 的允許版本 |
|------|-------------------------------|
| kubelet | 可舊 **3** 個 minor（1.28 起），不可比 apiserver 新 |
| kube-controller-manager / kube-scheduler | 可舊 1 個 minor，不可比 apiserver 新 |
| kube-proxy | 可舊 3 個 minor，不可比 apiserver 新 |
| kubectl | ±1 個 minor |
| kubeadm | 與目標版本相同（升級時先升 kubeadm） |

這決定了升級順序：**apiserver（Control Plane）→ kubelet/kube-proxy（Worker）→ kubectl**。

#### 8.3 相容性矩陣

安裝前確認以下組合，並記錄在決策表中：

| 元件 | 本指南版本 | 選型依據 / 注意事項 |
|------|-----------|-------------------|
| OS | Ubuntu 24.04 LTS | 支援至 2029；核心 6.8 原生 cgroup v2；`bento/ubuntu-24.04` box 現成可用 |
| 核心 | ≥ 5.10 建議 | Cilium eBPF 需求；VXLAN 與 nf_conntrack 在 4.x 即可 |
| cgroup driver | `systemd` | Ubuntu 24.04 為 cgroup v2，**containerd 與 kubelet 必須一致使用 systemd**，否則 kubelet 反覆重啟 |
| Kubernetes | 1.32 | 撰寫時的穩定版；`pkgs.k8s.io` 套件庫依 minor 版本分開 |
| containerd | Ubuntu 套件庫版本（1.7.x） | 需 ≥ 1.6 支援 CRI v1；使用 Docker 套件庫的 `containerd.io` 亦可 |
| runc | 隨 containerd | |
| CNI plugins | Flannel 自帶 | 若自行安裝需 ≥ 1.0 |
| Flannel | v0.25.5 | 支援 K8s 1.32；需搭配 `net-conf.json` Network 與 Pod CIDR 一致 |
| Calico（若選用） | 3.29+ | 需確認官方相容表支援目標 K8s 版本 |
| Cilium（若選用） | 1.16+ | 同上 |

> **檢查方式：** 每個 CNI / CSI 專案的 release note 或文件都有「Supported Kubernetes versions」表格，安裝前務必核對，不要假設最新版一定相容。

---

### 九、營運需求：監控、日誌、備份、升級

叢集裝好只是開始。以下項目在安裝前就應決定「要不要做、誰來做」，否則第一次出事才會發現什麼都沒有。

| 面向 | 需釐清的問題 | 建議方案 | 需預留 |
|------|-------------|---------|--------|
| **指標監控** | 要看到 Pod CPU/記憶體嗎？要告警嗎？ | `metrics-server`（HPA 必需）+ kube-prometheus-stack | Prometheus 需持久儲存（每節點每天約 1–2 GB） |
| **日誌集中** | 容器日誌要保留多久？誰會查？ | Loki + Promtail 或 EFK | 儲存空間；日誌保留政策 |
| **etcd 備份** | 可接受遺失多少分鐘的叢集狀態（RPO）？ | `etcdctl snapshot save` 排程（每小時 / 每日）+ 異地存放 | 備份目的地；還原演練時程 |
| **憑證管理** | 誰負責每年更新憑證？ | `kubeadm certs check-expiration` 加入監控；升級時自動更新 | 告警規則（到期前 30 天） |
| **升級策略** | 多久升級一次？維護時段？ | 每 6 個月跟進一個 minor；先在測試叢集演練 | 測試叢集；Worker drain 時的容量餘裕 |
| **叢集狀態備份** | 除了 etcd，YAML 定義存哪？ | GitOps（Argo CD / Flux），所有資源進 Git | Git repo；CI/CD 流程 |
| **容量告警** | 磁碟 / Pod IP / 節點資源用到多少要通知？ | 磁碟 80%、Pod CIDR 用量 70%、節點 CPU request 80% | 告警通道（Slack / Email / PagerDuty） |

---

### 十、需求分析輸出：安裝決策表

需求分析完成後，產出這張表，作為安裝時的唯一依據。右欄「事後可否變更」提醒哪些項目一定要在此刻確定。各項目在不同規模下的建議選擇與理由，見「進階議題」第五節「設計決策建議」。

以下是**本指南範例環境**的決策表：

| 決策項目 | 選項 | 本指南採用值 | 事後可否變更 |
|---------|------|------------|:-----------:|
| 叢集用途 | 學習 / 開發 / 正式 | 學習與 CKA/CKS 練習 | — |
| 節點數與規格 | — | 1 master（2 vCPU / 4 GB）+ 2 worker（2 vCPU / 2 GB） | ✅ 可加節點 |
| OS | — | Ubuntu 24.04 LTS | ❌ 換 OS = 重裝節點 |
| Kubernetes 版本 | — | 1.32 | ⚠️ 只能逐 minor 升級 |
| CRI | containerd / CRI-O | containerd（systemd cgroup） | ⚠️ 需逐節點 drain 重設 |
| Control Plane 拓撲 | 單一 / Stacked HA / External etcd | 單一 | ❌ 未設 endpoint，升 HA 需重簽憑證 |
| `--control-plane-endpoint` | DNS / VIP / 未設定 | 未設定（直接用 192.168.56.10） | ❌ 極難 |
| Node Network | — | 192.168.56.0/24（VirtualBox Host-only） | ❌ |
| Pod CIDR | — | 10.244.0.0/16（每節點 /24，最多 256 節點） | ❌ 需重建叢集 |
| Service CIDR | — | 10.96.0.0/12（預設） | ❌ 1.33+ 可用 ServiceCIDR 物件擴充，仍不建議 |
| 叢集 DNS 網域 | — | cluster.local（預設） | ❌ |
| CNI | Flannel / Calico / Cilium | Flannel v0.25.5（VXLAN，`--iface=eth1`） | ⚠️ 可換，需重建所有 Pod 網路 |
| kube-proxy 模式 | iptables / IPVS / eBPF | iptables（預設） | ✅ 改 ConfigMap 後重啟 |
| 對外入口 | NodePort / MetalLB / Ingress | NodePort（CKA 練習） | ✅ |
| 儲存 | — | 無 StorageClass（練習時用 hostPath / local PV） | ✅ |
| 稽核日誌 | 開 / 關 | 關（CKS 章節練習時手動開啟） | ⚠️ 需改 apiserver manifest |
| Secret 加密 | 開 / 關 | 關（CKS 章節練習時手動開啟） | ⚠️ 需改 apiserver manifest 並重寫 Secret |
| Pod Security Admission | — | 未設定（CKS 章節練習） | ✅ |
| 身分驗證 | admin.conf / OIDC | admin.conf | ⚠️ 加 OIDC 需改 apiserver manifest |
| 防火牆 | — | 關閉 UFW | ✅ |
| 監控 / 日誌 / 備份 | — | 無（練習環境可隨時 `vagrant destroy` 重建） | ✅ |

#### 將決策表轉成 kubeadm 設定檔

決策確定後，建議以 **kubeadm 設定檔**取代命令列參數，設定檔可進版控、可審閱、可重現。以下是把上表（並加上正式環境常見的幾項選擇）轉成 `kubeadm-config.yaml` 的範例：

```yaml
# kubeadm-config.yaml
# 用法：kubeadm init --config kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.56.10        # ← 決策：多網卡時選 Host-only 介面
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock   # ← 決策：CRI = containerd
  kubeletExtraArgs:
    - name: node-ip
      value: 192.168.56.10               # ← 決策：避免 kubelet 選到 NAT 介面
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: k8s-lab                     # ← 決策：叢集名稱（出現在 kubeconfig context）
kubernetesVersion: v1.32.0               # ← 決策：版本
# controlPlaneEndpoint: k8s-api.example.com:6443   # ← 決策：正式環境務必設定（本指南練習環境未設）
networking:
  podSubnet: 10.244.0.0/16               # ← 決策：Pod CIDR，須與 Flannel net-conf.json 一致
  serviceSubnet: 10.96.0.0/12            # ← 決策：Service CIDR
  dnsDomain: cluster.local               # ← 決策：叢集 DNS 網域
apiServer:
  extraArgs:
    # ← 決策：正式環境啟用稽核日誌（練習環境可省略）
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit/audit.log
    - name: audit-log-maxage
      value: "30"
    # ← 決策：Secret 靜態加密（練習環境可省略）
    # - name: encryption-provider-config
    #   value: /etc/kubernetes/enc/enc.yaml
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-log
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size
      value: "24"                        # ← 決策：每節點 Pod 子網大小
etcd:
  local:
    dataDir: /var/lib/etcd               # ← 決策：正式環境掛獨立 SSD 到此路徑
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd                    # ← 決策：與 containerd 一致
maxPods: 110                             # ← 決策：每節點 Pod 上限（須 < 子網可用 IP 數）
# 正式環境建議明確保留系統資源（見 3.2 Sizing 公式）
# kubeReserved:
#   cpu: 500m
#   memory: 1Gi
# systemReserved:
#   cpu: 500m
#   memory: 512Mi
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables                           # ← 決策：iptables / ipvs
```

> 用 `kubeadm config print init-defaults` 可以印出所有預設值作為起點；用 `kubeadm init --config kubeadm-config.yaml --dry-run` 可在不改動系統的情況下驗證設定檔。

---

### 十一、需求收集範本（可複製使用）

以下範本可直接複製到專案 Wiki 或 issue，逐項填寫後即成為安裝依據。

```markdown
# Kubernetes 叢集需求收集表

- 叢集名稱：
- 需求提出單位 / 聯絡人：
- 填寫日期：
- 預計上線日期：

## 1. 用途與情境
- [ ] 學習 / 實驗　[ ] 開發 / 測試　[ ] 正式營運　[ ] 其他：
- 主要工作負載類型（Web / DB / 批次 / AI）：
- 使用團隊數量與人數：
- 可接受的停機時間（每月）：

## 2. 規模
- 初期 Pod 數：　　　　1 年後預估：　　　　2 年後預估：
- 初期節點數：　　　　1 年後預估：　　　　2 年後預估：
- 單一 Pod 最大資源需求（CPU / 記憶體）：
- 是否需要 GPU：[ ] 是　[ ] 否

## 3. 高可用性
- Control Plane：[ ] 單一　[ ] 3 台 Stacked　[ ] External etcd
- Control Plane Endpoint（DNS / VIP）：
- 負載平衡器方案：

## 4. 網路（需網路團隊確認）
- Node Network：
- Pod CIDR：　　　　　　（已確認不與 ______ 重疊）
- Service CIDR：　　　　（已確認不與 ______ 重疊）
- 叢集 DNS 網域：
- CNI：[ ] Flannel　[ ] Calico　[ ] Cilium
- 需要 NetworkPolicy：[ ] 是　[ ] 否
- 節點是否多網卡：[ ] 是（叢集介面：______）　[ ] 否
- 實體 MTU：　　　　底層是否已有 overlay：[ ] 是　[ ] 否
- 對外入口：[ ] NodePort　[ ] MetalLB（IP 池：______）　[ ] 雲端 LB　[ ] Ingress
- 連外方式：[ ] 直連　[ ] Proxy（位址：______）　[ ] 離線（registry：______）
- 防火牆申請單號：

## 5. 儲存
- 需要持久儲存：[ ] 是　[ ] 否
- 需要 RWX：[ ] 是　[ ] 否
- 需要快照 / 備份：[ ] 是　[ ] 否
- 方案：[ ] local　[ ] NFS　[ ] Longhorn　[ ] Ceph　[ ] 雲端 CSI　[ ] 企業儲存：______
- 預估容量：　　　　IOPS 需求：

## 6. 安全與合規
- 適用規範：[ ] CIS　[ ] ISO 27001　[ ] 個資法　[ ] PCI DSS　[ ] 其他：
- 稽核日誌：[ ] 啟用（保留 ___ 天）　[ ] 不啟用
- Secret 靜態加密：[ ] 啟用　[ ] 不啟用
- 身分驗證：[ ] kubeconfig　[ ] OIDC（Provider：______）
- Pod Security 等級：[ ] privileged　[ ] baseline　[ ] restricted
- 映像來源限制：[ ] 僅私有 registry　[ ] 不限制

## 7. 版本
- OS：　　　　　Kubernetes：　　　　　CRI：
- CNI 版本：　　　CSI 版本：
- 相容性已核對：[ ] 是（核對者：______）

## 8. 營運
- 監控方案：　　　　　負責人：
- 日誌方案：　　　　　保留天數：
- etcd 備份頻率：　　　備份存放位置：
- 升級週期：　　　　　維護時段：
- GitOps：[ ] 是（repo：______）　[ ] 否

## 9. 決策紀錄
| 日期 | 決策項目 | 決定 | 決策者 | 理由 |
|------|---------|------|--------|------|
|      |         |      |        |      |
```

---

## 方法二：手動逐步安裝（含原理說明）

## 環境需求

> 以下環境是依「安裝前需求收集與分析」第十節決策表所選定的**學習用**組態。正式環境請依該章重新評估節點規格、HA 拓撲與網段規劃。

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

# 進階議題：性能調優、高可用設計、備份與災難復原

「安裝前需求收集與分析」章節決定了**要不要**做這些事；本章說明**怎麼做**。四個主題彼此相關：調優不當會拖垮 HA、HA 不代表不用備份、備份沒演練過等於沒有災難復原。

```
┌──────────────────────────────────────────────────────────────────┐
│                        叢集韌性金字塔                              │
│                                                                    │
│                      ┌────────────┐                                │
│                      │  災難復原   │  ← 叢集毀了怎麼救回來            │
│                    ┌─┴────────────┴─┐                              │
│                    │     備份        │  ← 有東西可以救                │
│                  ┌─┴────────────────┴─┐                            │
│                  │     高可用設計       │  ← 單點故障不停機            │
│                ┌─┴────────────────────┴─┐                          │
│                │       性能調優           │  ← 在負載下仍然穩定        │
│              ┌─┴────────────────────────┴─┐                        │
│              │   正確安裝 + 監控（前面章節）  │                        │
│              └────────────────────────────┘                        │
└──────────────────────────────────────────────────────────────────┘
```

本章所有指令均以本指南的 kubeadm + containerd + Flannel 環境為基礎（Kubernetes 1.32、etcd 3.5）。若只想知道「該怎麼選」，可直接跳到第五節「設計決策建議」。

---

## 一、性能調優

### 1.1 調優的層次

效能問題必須先定位在哪一層，再對症下藥。由下而上：

| 層次 | 常見瓶頸 | 觀察指標 |
|------|---------|---------|
| OS / 核心 | 檔案描述符、inotify、conntrack 表滿、CPU 頻率 | `dmesg`、`/proc/sys/*`、`node_exporter` |
| 容器執行期 | 映像拉取慢、overlayfs 層數過多 | `crictl stats`、拉取時間 |
| kubelet / 節點 | 資源未保留、Pod 密度過高、驅逐風暴 | `kubectl describe node`、kubelet metrics |
| etcd | 磁碟 fsync 延遲、DB 過大、碎片化 | `etcd_disk_wal_fsync_duration_seconds` |
| kube-apiserver | 請求排隊、watch 過多、大 list 請求 | `apiserver_request_duration_seconds`、APF 指標 |
| 排程 / 控制器 | 排程延遲、控制器 QPS 限制 | `scheduler_scheduling_attempt_duration_seconds` |
| 網路 | iptables 規則數、DNS 延遲、VXLAN 開銷 | `iperf3`、CoreDNS metrics |
| 工作負載 | CPU throttling、記憶體 OOM、probe 設定不當 | `container_cpu_cfs_throttled_periods_total` |

> **原則：先量測、再調整、再量測。** 沒有指標的調優是猜測。建議先安裝 `metrics-server` 與 kube-prometheus-stack（見 1.9），再進行以下調整。

### 1.2 OS 與核心層

本指南安裝步驟只設定了最低限度的核心參數（`ip_forward`、`bridge-nf-call-iptables`）。正式環境建議額外調整：

```bash
sudo tee /etc/sysctl.d/99-k8s-tuning.conf <<'SYSCTL'
# --- 檔案與 inotify（大量 Pod / 日誌 tail 時必調）---
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
fs.aio-max-nr = 1048576

# --- 網路連線 ---
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600

# --- conntrack（kube-proxy iptables/IPVS 模式依賴；表滿會隨機掉封包）---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

# --- ARP 快取（大型叢集 Pod 數多時，預設 gc_thresh 太小會出現 neighbor table overflow）---
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# --- 記憶體 ---
vm.max_map_count = 262144        # Elasticsearch / 大型 JVM 需要
vm.swappiness = 0                # Swap 已停用，保險起見
vm.overcommit_memory = 1
SYSCTL
sudo sysctl --system
```

其他 OS 層設定：

| 項目 | 設定 | 說明 |
|------|------|------|
| CPU 頻率調節 | `cpupower frequency-set -g performance` | VM 通常無此選項；實體機必調，避免 `powersave` 造成延遲抖動 |
| Transparent Huge Pages | `echo never > /sys/kernel/mm/transparent_hugepage/enabled` | 資料庫（MySQL、Redis、MongoDB）官方建議關閉 |
| 時間同步 | `chrony` 或 `systemd-timesyncd` | 憑證驗證與 etcd 都依賴節點時間一致；漂移 > 幾秒會出現詭異的 TLS 錯誤 |
| containerd 檔案描述符上限 | 確認 `systemctl show containerd -p LimitNOFILE` 足夠大（≥ 1048576） | 上游 unit 檔預設為 `infinity` |
| NIC 多佇列 / RSS | `ethtool -L eth1 combined <CPU 數>` | 高流量節點讓多核分擔中斷處理 |
| irqbalance | `systemctl enable --now irqbalance` | 讓網卡中斷分散到不同 CPU |

### 1.3 etcd 調優

etcd 是整個叢集的效能天花板：**所有** API 寫入都要等 etcd 把 WAL fsync 到磁碟才回應。

#### 磁碟效能是第一優先

安裝前用 `fio` 驗證磁碟是否合格（etcd 官方建議的測試方式）：

```bash
sudo apt install -y fio
mkdir -p /var/lib/etcd-fio-test
fio --rw=write --ioengine=sync --fdatasync=1 \
    --directory=/var/lib/etcd-fio-test --size=22m --bs=2300 --name=etcd-test
# 觀察 fsync/fdatasync 的 99th percentile：
#   99.00th=[ 3000] （單位 usec）→ 3ms ✅ 合格
#   99.00th=[25000]              → 25ms ❌ 不合格，會頻繁 leader 選舉
rm -rf /var/lib/etcd-fio-test
```

| 指標 | 健康門檻 | 超過時的症狀 |
|------|---------|-------------|
| `etcd_disk_wal_fsync_duration_seconds` p99 | < 10ms | apiserver 回應變慢、`etcdserver: request timed out` |
| `etcd_disk_backend_commit_duration_seconds` p99 | < 25ms | 同上 |
| `etcd_server_leader_changes_seen_total` | 應接近 0 | 頻繁 leader 切換，叢集短暫不可寫 |
| `etcd_mvcc_db_total_size_in_bytes` | < quota 的 80% | 達到 quota 觸發 `NOSPACE` alarm，**叢集變唯讀** |
| `etcd_network_peer_round_trip_time_seconds` | < 50ms | 跨區部署延遲過高 |

#### etcd 參數調整

透過 kubeadm 設定檔（`ClusterConfiguration.etcd.local.extraArgs`）或直接編輯 `/etc/kubernetes/manifests/etcd.yaml`：

```yaml
etcd:
  local:
    dataDir: /var/lib/etcd                 # 掛獨立 SSD
    extraArgs:
      - name: quota-backend-bytes
        value: "8589934592"                # 8 GiB（預設 2 GiB；官方建議上限 8 GiB）
      - name: auto-compaction-mode
        value: periodic
      - name: auto-compaction-retention
        value: "1h"                        # 每小時壓縮歷史版本，控制 DB 成長
      - name: snapshot-count
        value: "10000"                     # kubeadm 預設；記憶體充足可調大以減少快照 I/O
      # 跨區部署（節點間 RTT > 10ms）才需要調整以下兩項，同區保持預設
      # - name: heartbeat-interval
      #   value: "250"                     # 預設 100ms
      # - name: election-timeout
      #   value: "2500"                    # 預設 1000ms；建議為 heartbeat 的 10 倍
```

#### 定期維護指令

```bash
# 設定 etcdctl 環境變數（以下指令共用）
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key

# 查看 DB 大小、leader、raft index
sudo -E etcdctl endpoint status --write-out=table

# 手動壓縮到目前版本（auto-compaction 已啟用時通常不需要）
REV=$(sudo -E etcdctl endpoint status --write-out=json | jq -r '.[0].Status.header.revision')
sudo -E etcdctl compact "$REV"

# 碎片整理：釋放壓縮後的空間給 OS。會短暫阻塞該成員，HA 叢集請一次做一台，離峰執行
sudo -E etcdctl defrag

# 若已觸發 NOSPACE alarm（叢集唯讀），先 compact + defrag，再解除警報
sudo -E etcdctl alarm list
sudo -E etcdctl alarm disarm
```

> **Events 分流：** 大型叢集中 Event 物件佔 etcd 寫入量的大宗。可用獨立 etcd 叢集存放 Events：apiserver 加上 `--etcd-servers-overrides=/events#https://etcd-events-1:2379,https://etcd-events-2:2379`。這是 GKE / EKS 等託管服務的標準做法。

### 1.4 kube-apiserver 調優

| 參數 | 預設 | 調整建議 | 說明 |
|------|-----|---------|------|
| `--max-requests-inflight` | 400 | 大型叢集 800–1600 | 唯讀請求同時處理上限 |
| `--max-mutating-requests-inflight` | 200 | 大型叢集 400–800 | 寫入請求同時處理上限 |
| API Priority and Fairness（APF） | 啟用 | 保持啟用；為關鍵元件建立 `FlowSchema` | 取代舊的簡單限流，避免單一使用者/控制器塞爆 apiserver |
| `--event-ttl` | 1h | 保持或縮短 | Event 保留時間，縮短可降低 etcd 壓力 |
| `--watch-cache-sizes` | 自動 | 通常不調 | 特定資源 watch 量極大時才指定 |
| `--audit-log-*` | 關閉 | 啟用時搭配精簡 policy | 稽核 `RequestResponse` 等級對所有資源會顯著增加延遲與磁碟寫入 |
| Static Pod 資源 | CPU request 250m | 正式環境加上 limit 並提高 request | kubeadm 預設無 limit，避免 apiserver 被其他 Pod 擠壓 |

```yaml
# kubeadm ClusterConfiguration 片段
apiServer:
  extraArgs:
    - name: max-requests-inflight
      value: "800"
    - name: max-mutating-requests-inflight
      value: "400"
    - name: event-ttl
      value: "30m"
```

**用戶端行為對 apiserver 的影響（常被忽略）：**

- 避免 `kubectl get pods -A` 這類**全叢集 list**在監控腳本中高頻執行；改用 `watch` 或 informer。
- 自訂 Controller / Operator 使用 client-go 時應設定合理的 QPS/Burst，並使用 informer cache 而非直接 GET。
- 大量 `kubectl exec` / `logs -f` 會佔用 apiserver 連線（流量經 apiserver 轉發到 kubelet）。

觀察指標：

```promql
# apiserver 請求延遲 p99（依 verb 與資源）
histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[5m])) by (le, verb, resource))

# APF 排隊 / 拒絕情況
sum(rate(apiserver_flowcontrol_rejected_requests_total[5m])) by (priority_level, reason)
```

### 1.5 kube-controller-manager 與 kube-scheduler

| 元件 | 參數 | 預設 | 說明 |
|------|------|-----|------|
| 兩者 | `--kube-api-qps` / `--kube-api-burst` | 20 / 30 | 控制器對 apiserver 的請求速率。節點數 > 500 時提高到 100 / 200，否則大量 Pod 變更時控制器會排隊 |
| KCM | `--concurrent-deployment-syncs` 等 `--concurrent-*` | 5 | 各控制器的平行工作數，Deployment 數量多時可提高 |
| KCM | `--node-monitor-grace-period` | 40s | kubelet 多久沒回報就標記 NotReady（見 2.6 節點故障時序） |
| KCM | `--node-cidr-mask-size` | 24 | 每節點 Pod 子網大小（見需求分析 5.2） |
| Scheduler | `percentageOfNodesToScore` | 自動（50% → 5%） | 大型叢集只對部分節點打分以加速排程；節點 < 100 時等於全部 |
| Scheduler | 多 Profile / Plugin | — | 可為批次工作負載建立偏好 bin-packing 的 profile（`NodeResourcesFit` 的 `MostAllocated` 策略） |

排程器吞吐量在預設設定下約 **100 Pod/秒**；若有大量 Job 短時間內建立數千 Pod，需要觀察 `scheduler_pending_pods` 是否堆積。

### 1.6 kubelet 與節點層

#### 資源保留與驅逐

正式環境**必須**設定資源保留，否則 Pod 會把 kubelet / containerd / sshd 的資源吃光，造成節點失聯：

```yaml
# KubeletConfiguration（kubeadm 透過 kubelet-config ConfigMap 統一管理）
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
kubeReserved:
  cpu: 500m
  memory: 1Gi
  ephemeral-storage: 5Gi
systemReserved:
  cpu: 500m
  memory: 512Mi
  ephemeral-storage: 5Gi
evictionHard:
  memory.available: "500Mi"      # 預設 100Mi 太晚，OOM killer 可能先動手
  nodefs.available: "10%"
  imagefs.available: "15%"
  nodefs.inodesFree: "5%"
evictionSoft:
  memory.available: "1Gi"
evictionSoftGracePeriod:
  memory.available: "1m30s"
enforceNodeAllocatable: ["pods"]
```

修改後套用到所有節點：

```bash
# 編輯叢集層級的 kubelet 設定
kubectl edit cm kubelet-config -n kube-system
# 逐節點套用（需 drain）
sudo kubeadm upgrade node phase kubelet-config && sudo systemctl restart kubelet
```

#### Pod 密度與拉取效能

| 參數 | 預設 | 建議 | 說明 |
|------|-----|------|------|
| `maxPods` | 110 | 依節點規格；大節點（64 核）可 200–250 | 受 Pod 子網 IP 數限制 |
| `podPidsLimit` | -1（不限） | 4096 | 防止單一 Pod fork bomb 拖垮節點 |
| `serializeImagePulls` | true | false | 允許平行拉取映像，大幅縮短多 Pod 同時啟動時間 |
| `maxParallelImagePulls` | 無限制 | 5–10 | 搭配上一項，避免打爆 registry |
| `registryPullQPS` / `registryBurst` | 5 / 10 | 依 registry 能力 | 對私有 registry 可調高 |
| `imageGCHighThresholdPercent` / `Low` | 85 / 80 | 磁碟小的節點調低 | 磁碟用量超過 High 時開始清理未使用映像 |
| `containerLogMaxSize` / `Files` | 10Mi / 5 | 高流量服務調大 | 超過即輪替，舊日誌丟失 |
| `nodeStatusReportFrequency` | 5m | 保持 | 節點狀態上報間隔，調短會增加 apiserver 壓力 |

#### CPU 綁核與 NUMA（延遲敏感工作負載）

```yaml
cpuManagerPolicy: static          # Guaranteed QoS 且 CPU 為整數的 Pod 獨占 CPU 核心
reservedSystemCPUs: "0,1"         # 保留給系統的核心（static policy 必須設定）
topologyManagerPolicy: single-numa-node   # 確保 CPU、記憶體、裝置在同一 NUMA 節點
memoryManagerPolicy: Static
```

適用：資料庫、即時串流、DPDK、AI 推論。一般 Web 服務不需要，且會降低整體利用率。

#### containerd 調優

```toml
# /etc/containerd/config.toml 片段
[plugins."io.containerd.grpc.v1.cri"]
  # 映像拉取平行度（containerd 端）
  max_concurrent_downloads = 10
  # Registry 鏡像：離線環境或加速拉取
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"

[plugins."io.containerd.grpc.v1.cri".containerd]
  # 拉取後丟棄已解壓的 layer 內容，節省磁碟（會使 push/export 變慢）
  discard_unpacked_layers = true
```

```bash
# Registry 鏡像設定範例：docker.io → 私有 Harbor
sudo mkdir -p /etc/containerd/certs.d/docker.io
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml <<'TOML'
server = "https://registry-1.docker.io"
[host."https://harbor.example.com/v2/dockerhub"]
  capabilities = ["pull", "resolve"]
  override_path = true
TOML
sudo systemctl restart containerd
```

其他做法：以 DaemonSet 預先拉取（pre-pull）核心映像、使用 `imagePullPolicy: IfNotPresent`、在 CI 中把基礎映像層數控制在 10 層以內。

### 1.7 網路層調優

#### kube-proxy 模式

| 模式 | 規則複雜度 | 適用規模 | 說明 |
|------|-----------|---------|------|
| `iptables`（預設） | O(n)，每個 Service/Endpoint 一組鏈 | < 1,000 Service | Service 數多時，規則同步耗時數秒到數十秒，新 Endpoint 生效延遲 |
| `ipvs` | O(1) hash 查表 | > 1,000 Service | 支援 rr / lc / sh 等排程演算法；需載入 IPVS 核心模組 |
| `nftables` | 較 iptables 高效 | 1.31+ beta、1.33 GA | 未來預設；1.32 可測試 |
| eBPF（Cilium 取代 kube-proxy） | 最高 | 任何規模 | 完全繞過 netfilter，需換 CNI |

切換到 IPVS：

```bash
# 1. 所有節點載入模組
cat <<'MOD' | sudo tee /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
MOD
sudo modprobe ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack
sudo apt install -y ipvsadm ipset

# 2. 修改 kube-proxy 設定
kubectl edit cm kube-proxy -n kube-system
#   mode: "ipvs"
#   ipvs:
#     scheduler: "rr"
#     strictARP: true        # MetalLB L2 模式需要

# 3. 重啟 kube-proxy
kubectl rollout restart ds kube-proxy -n kube-system

# 4. 驗證
sudo ipvsadm -Ln | head -20
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep -i "Using ipvs Proxier"
```

#### conntrack

kube-proxy 會依 CPU 數自動設定 `nf_conntrack_max`（`conntrack.maxPerCore: 32768`，最低 `min: 131072`）。高連線數節點（API Gateway、Ingress）可提高：

```yaml
# kube-proxy ConfigMap
conntrack:
  maxPerCore: 65536
  min: 524288
  tcpEstablishedTimeout: 24h0m0s
  tcpCloseWaitTimeout: 1h0m0s
```

表滿的症狀：`dmesg` 出現 `nf_conntrack: table full, dropping packet`，連線隨機失敗。

#### DNS 效能

DNS 是 Kubernetes 網路最常見的效能瓶頸，因為 **每個 Pod 的每次外部連線都可能先發 5 次 DNS 查詢**：

```
Pod 內 /etc/resolv.conf：
  search default.svc.cluster.local svc.cluster.local cluster.local
  options ndots:5

查詢 api.example.com（點數 2 < ndots 5）→ 依序嘗試：
  api.example.com.default.svc.cluster.local   ← NXDOMAIN
  api.example.com.svc.cluster.local           ← NXDOMAIN
  api.example.com.cluster.local               ← NXDOMAIN
  api.example.com                             ← 成功
（每次都是 A + AAAA 兩個查詢，共 8 次往返）
```

| 對策 | 做法 | 效果 |
|------|------|------|
| **NodeLocal DNSCache** | 每節點跑一個 DNS 快取 DaemonSet（監聽 169.254.20.10），Pod 先問本機 | 消除跨節點 DNS 流量與 conntrack 競爭，官方推薦 |
| 調整 `ndots` | Pod spec 加 `dnsConfig.options: [{name: ndots, value: "2"}]` | 外部網域直接查詢，少 6 次往返 |
| 使用 FQDN | 程式碼中寫 `api.example.com.`（結尾加點） | 跳過 search list |
| CoreDNS 擴容 | `cluster-proportional-autoscaler` 依節點數自動調整副本 | 預設 2 副本在大叢集不夠 |
| CoreDNS cache | Corefile 中 `cache 30` 已預設啟用；可調整 TTL | 減少上游查詢 |

```bash
# 安裝 NodeLocal DNSCache
KUBEDNS=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
curl -sLO https://raw.githubusercontent.com/kubernetes/kubernetes/master/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml
sed -i "s/__PILLAR__LOCAL__DNS__/169.254.20.10/g; s/__PILLAR__DNS__DOMAIN__/cluster.local/g; s/__PILLAR__DNS__SERVER__/$KUBEDNS/g" nodelocaldns.yaml
kubectl apply -f nodelocaldns.yaml
# 之後需將 kubelet clusterDNS 改指向 169.254.20.10（iptables 模式的 kube-proxy 可不改，NodeLocal 會攔截）
```

#### CNI 與封裝開銷

| 模式 | 每封包額外開銷 | 相對吞吐 | 條件 |
|------|--------------|---------|------|
| Flannel VXLAN（本指南） | 50 bytes 封裝 + 核心處理 | 基準 100% | 任何 L3 網路 |
| Flannel host-gw | 無封裝 | ~110–120% | 所有節點在**同一 L2 網段** |
| Calico BGP / Cilium native routing | 無封裝 | ~110–120% | 同上，或路由器支援 BGP |
| Cilium eBPF + XDP | 無封裝 + 繞過 netfilter | ~120–130% | 核心 ≥ 5.10 |
| Jumbo Frame（MTU 9000） | 封裝比例降低 | 大檔案傳輸顯著提升 | 整條路徑（交換器、NIC）都支援 |

本指南的 Vagrant 環境節點都在 `192.168.56.0/24` 同一 L2，可將 Flannel 改為 host-gw 模式測試差異：

```bash
kubectl edit cm kube-flannel-cfg -n kube-flannel
#   net-conf.json: "Backend": {"Type": "host-gw"}
kubectl rollout restart ds kube-flannel-ds -n kube-flannel
ip route | grep 10.244   # 應變成 via 192.168.56.x dev eth1（不再經過 flannel.1）
```

用 `iperf3` 量測 Pod 間頻寬：

```bash
kubectl run iperf-server --image=networkstatic/iperf3 --port=5201 -- -s
kubectl wait --for=condition=Ready pod/iperf-server
SERVER_IP=$(kubectl get pod iperf-server -o jsonpath='{.status.podIP}')
# 用 nodeSelector 確保 client 在不同節點
kubectl run iperf-client --rm -it --image=networkstatic/iperf3 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"k8s-worker2"}}}' \
  -- -c $SERVER_IP -t 10
kubectl delete pod iperf-server
```

### 1.8 工作負載層

#### requests / limits 的正確設定

```
CPU：
  request  → 排程依據 + cgroup cpu.shares（保證最低比例）
  limit    → cgroup CFS quota（每 100ms 週期最多用多少）
             ⚠ 即使節點 CPU 閒置，超過 limit 仍會被 throttle → 延遲飆高

記憶體：
  request  → 排程依據
  limit    → cgroup memory.max，超過直接 OOMKilled
```

| 建議 | 理由 |
|------|------|
| **所有 Pod 都設 request** | 沒 request 的 Pod（BestEffort）會被排程器塞滿節點，最先被驅逐 |
| **記憶體 request = limit** | 記憶體無法壓縮；不相等時節點超賣，OOM 時殺誰難以預測 |
| **CPU 慎設 limit，或 limit 設為 request 的 2–4 倍** | CFS throttling 是延遲敏感服務最常見的效能殺手；Guaranteed QoS 需要 request = limit，但多數服務不需要 Guaranteed |
| 用 **LimitRange** 設定 namespace 預設值 | 防止開發者忘記設定 |
| 用 **VPA**（recommendation 模式）找出合理值 | 比猜測準確 |

觀察 throttling：

```promql
# 每個容器被 throttle 的週期比例；> 25% 就該提高 limit 或移除
sum(rate(container_cpu_cfs_throttled_periods_total[5m])) by (namespace, pod, container)
  / sum(rate(container_cpu_cfs_periods_total[5m])) by (namespace, pod, container)
```

#### QoS 與 PriorityClass

| QoS | 條件 | 節點壓力時的驅逐順序 |
|-----|------|-------------------|
| Guaranteed | 所有容器 request = limit（CPU 與記憶體） | 最後 |
| Burstable | 至少一個容器有 request，但不滿足 Guaranteed | 中間（超出 request 越多越先） |
| BestEffort | 完全沒設 | 最先 |

搭配 `PriorityClass` 讓關鍵服務在資源不足時**搶佔**低優先 Pod：

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: business-critical
value: 1000000
globalDefault: false
description: "核心交易服務"
---
# Pod spec 中加上
#   priorityClassName: business-critical
```

#### Probe 設定

| Probe | 常見錯誤 | 建議 |
|-------|---------|------|
| liveness | 檢查外部依賴（DB）→ DB 慢時全部 Pod 被重啟，雪崩 | 只檢查程序本身是否卡死 |
| readiness | `initialDelaySeconds` 太短 → 未就緒就收流量 | 改用 `startupProbe` 處理慢啟動 |
| 全部 | `timeoutSeconds: 1`（預設）→ GC 停頓就失敗 | 3–5 秒 |

#### 自動擴縮

- **HPA**：以 CPU/記憶體或自訂指標（Prometheus Adapter / KEDA）擴縮副本；設定 `behavior` 避免抖動。
- **VPA**：調整 request/limit；不要與 HPA 同時對 CPU 作用。
- **Cluster Autoscaler / Karpenter**：雲端環境自動加減節點；地端可用 Cluster API 或手動。

### 1.9 效能監控與基準測試

#### 必裝元件

```bash
# metrics-server（kubectl top、HPA 依賴）
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# 自簽憑證環境（本指南 Vagrant）需加 --kubelet-insecure-tls
kubectl patch deploy metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# kube-prometheus-stack（Prometheus + Grafana + Alertmanager + 預設儀表板與告警規則）
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi
```

#### 關鍵 SLI

| 層 | 指標 | 目標 |
|----|------|------|
| apiserver | 非 watch 請求 p99 延遲 | < 1s（list）/ < 0.1s（get） |
| etcd | WAL fsync p99 | < 10ms |
| scheduler | `scheduler_scheduling_attempt_duration_seconds` p99 | < 1s |
| Pod 啟動 | 從建立到 Running（不含拉取映像） | < 5s |
| DNS | CoreDNS `coredns_dns_request_duration_seconds` p99 | < 10ms |
| 節點 | CPU / 記憶體 request 佔比 | < 80%（留餘裕給故障轉移） |

#### 基準測試工具

| 工具 | 用途 |
|------|------|
| `kube-burner` | 大規模建立 Pod/Deployment，量測 apiserver 與排程吞吐 |
| `clusterloader2` | Kubernetes 官方的可擴展性測試框架 |
| `sonobuoy` | Conformance 測試，確認叢集行為符合上游 |
| `fio` | 磁碟（etcd、PV） |
| `iperf3` | Pod / 節點間網路頻寬 |
| `k6` / `wrk` | 應用層 HTTP 負載 |
| `dnsperf` | DNS 查詢吞吐 |

---

## 二、高可用設計

需求分析章節第四節說明了 HA 拓撲的**選擇**；本節說明**如何建置**，以及 Control Plane 之外常被忽略的 HA 層面。

### 2.1 HA 的六個層次

```
┌─────────────────────────────────────────────────────────────────┐
│ 6. 跨站點 / 多叢集      DNS 故障轉移、GitOps 同步、資料複製          │
├─────────────────────────────────────────────────────────────────┤
│ 5. 儲存                 多副本 (Longhorn/Ceph)、DB 自身複製          │
├─────────────────────────────────────────────────────────────────┤
│ 4. 入口與 DNS           Ingress 多副本、MetalLB/BGP、CoreDNS 反親和   │
├─────────────────────────────────────────────────────────────────┤
│ 3. 工作負載             多副本、反親和、PDB、優雅關閉                │
├─────────────────────────────────────────────────────────────────┤
│ 2. etcd                 3/5 成員、獨立磁碟、跨故障域                │
├─────────────────────────────────────────────────────────────────┤
│ 1. Control Plane        3 apiserver + LB/VIP、Leader Election      │
└─────────────────────────────────────────────────────────────────┘
```

**只做第 1、2 層是最常見的錯誤**：Control Plane 全活著，但 Ingress Controller 只有一個副本掛在故障的節點上，使用者一樣看到 502。

### 2.2 Stacked etcd HA 建置（kubeadm）

以下以 3 Control Plane + 2 Worker 為例，沿用本指南的 Host-only 網段：

| 角色 | 主機名稱 | IP |
|------|---------|-----|
| VIP（apiserver 入口） | `k8s-api` | 192.168.56.100 |
| Control Plane 1 | k8s-cp1 | 192.168.56.10 |
| Control Plane 2 | k8s-cp2 | 192.168.56.11 |
| Control Plane 3 | k8s-cp3 | 192.168.56.12 |
| Worker | k8s-worker1/2 | 192.168.56.21 / 22 |

```
                     kubectl / Worker kubelet
                              │
                              ▼
                   VIP 192.168.56.100:6443
                   (kube-vip 或 keepalived+HAProxy)
                    ┌─────────┼─────────┐
                    ▼         ▼         ▼
               ┌────────┐┌────────┐┌────────┐
               │  cp1   ││  cp2   ││  cp3   │
               │ api    ││ api    ││ api    │  ← 三個 apiserver 同時服務（無狀態）
               │ etcd ◄─┼┼─etcd ◄─┼┼─etcd   │  ← Raft：一個 leader，兩個 follower
               │ sched  ││ sched  ││ sched  │  ← Leader Election：只有一個 active
               │ ctrl   ││ ctrl   ││ ctrl   │  ← 同上
               └────────┘└────────┘└────────┘
```

#### 步驟 1：所有節點完成共同設定

執行方法二「一、所有節點共同設定」的全部步驟（Swap、核心模組、containerd、kubeadm）。

#### 步驟 2：建立 VIP — 方案 A：kube-vip（推薦，無需額外機器）

在 **cp1** 執行：

```bash
export VIP=192.168.56.100
export INTERFACE=eth1
export KVVERSION=v0.8.9   # 請至 https://github.com/kube-vip/kube-vip/releases 確認最新版

# 以 containerd 直接跑 kube-vip 產生 static Pod manifest
sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip \
  /kube-vip manifest pod \
    --interface $INTERFACE \
    --address $VIP \
    --controlplane \
    --arp \
    --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

> **Kubernetes 1.29+ 的雞生蛋問題：** `kubeadm init` 期間 `admin.conf` 尚無 cluster-admin 權限，kube-vip 會無法做 leader election，導致 VIP 起不來、init 卡住。解法：在第一台 init **之前**把 manifest 中的 `/etc/kubernetes/admin.conf` 改為 `/etc/kubernetes/super-admin.conf`，init 完成後再改回來：
>
> ```bash
> sudo sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml
> # ... kubeadm init 完成後 ...
> sudo sed -i 's#path: /etc/kubernetes/super-admin.conf#path: /etc/kubernetes/admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml
> ```

#### 步驟 2：建立 VIP — 方案 B：HAProxy + keepalived（傳統做法）

在**每台 Control Plane** 安裝：

```bash
sudo apt install -y haproxy keepalived
```

```
# /etc/haproxy/haproxy.cfg
frontend k8s-api
    bind *:8443                      # 用 8443 避免與本機 apiserver 的 6443 衝突
    mode tcp
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    balance roundrobin
    option httpchk GET /healthz
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 check check-ssl verify none
    server cp1 192.168.56.10:6443
    server cp2 192.168.56.11:6443
    server cp3 192.168.56.12:6443
```

```
# /etc/keepalived/keepalived.conf（cp1 為 MASTER priority 101，其餘 BACKUP priority 100）
vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight -20
}
vrrp_instance VI_1 {
    state MASTER
    interface eth1
    virtual_router_id 51
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k8s-vip
    }
    virtual_ipaddress {
        192.168.56.100/24
    }
    track_script {
        check_haproxy
    }
}
```

```bash
sudo systemctl enable --now haproxy keepalived
ip addr show eth1 | grep 192.168.56.100   # 只在 MASTER 上看到 VIP
```

此方案的 `--control-plane-endpoint` 為 `192.168.56.100:8443`。

#### 步驟 3：初始化第一台 Control Plane

```bash
# cp1
sudo kubeadm init \
  --control-plane-endpoint "192.168.56.100:6443" \
  --apiserver-advertise-address 192.168.56.10 \
  --pod-network-cidr 10.244.0.0/16 \
  --upload-certs

# 輸出會有兩段 join 指令，務必保存：
#   (a) 加入 Control Plane：kubeadm join 192.168.56.100:6443 --token ... \
#         --discovery-token-ca-cert-hash sha256:... \
#         --control-plane --certificate-key <64 hex>
#   (b) 加入 Worker：kubeadm join 192.168.56.100:6443 --token ... \
#         --discovery-token-ca-cert-hash sha256:...
```

`--upload-certs` 會把 PKI 憑證加密後存入 Secret `kubeadm-certs`，供其他 Control Plane 下載；**`certificate-key` 兩小時後失效**，過期後重新產生：

```bash
sudo kubeadm init phase upload-certs --upload-certs
```

接著設定 kubectl、部署 Flannel（同方法二步驟；Flannel 的 `--iface=eth1` 設定不變）。

#### 步驟 4：加入其他 Control Plane

```bash
# cp2、cp3（先在每台複製 kube-vip manifest 或設好 HAProxy/keepalived）
sudo kubeadm join 192.168.56.100:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <key> \
  --apiserver-advertise-address 192.168.56.11    # cp3 改為 .12
```

kubeadm 會自動：下載憑證 → 產生本機 apiserver / etcd 憑證 → 以 `etcdctl member add` 加入 etcd 叢集 → 啟動 static Pod。

#### 步驟 5：驗證

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide | grep -E "etcd|apiserver|kube-vip"

# etcd 成員與健康狀態（在任一 cp 執行，使用 1.3 節的環境變數）
sudo -E etcdctl member list --write-out=table
sudo -E etcdctl endpoint health --cluster --write-out=table

# 故障轉移測試：關掉 cp1，VIP 應在數秒內漂移，kubectl 持續可用
vagrant halt k8s-cp1        # 或 sudo systemctl stop kubelet && sudo systemctl stop containerd
watch kubectl get nodes
```

### 2.3 External etcd 拓撲要點

與 Stacked 的差異只在 etcd 獨立部署：

1. 在 3 台 etcd 節點上以 kubeadm 產生憑證並用 static Pod 跑 etcd（官方文件「Set up a High Availability etcd cluster with kubeadm」）。
2. 把 etcd 的 `ca.crt`、`apiserver-etcd-client.crt/key` 複製到第一台 Control Plane。
3. `kubeadm init --config` 中指定：

```yaml
etcd:
  external:
    endpoints:
      - https://192.168.56.31:2379
      - https://192.168.56.32:2379
      - https://192.168.56.33:2379
    caFile: /etc/kubernetes/pki/etcd/ca.crt
    certFile: /etc/kubernetes/pki/apiserver-etcd-client.crt
    keyFile: /etc/kubernetes/pki/apiserver-etcd-client.key
```

適用時機：Control Plane 節點資源緊張、需要獨立擴縮 etcd、或安全政策要求 etcd 與 apiserver 隔離。代價是機器數加倍、維運面加寬。

### 2.4 Control Plane 元件的 HA 機制

| 元件 | 機制 | 說明 |
|------|------|------|
| kube-apiserver | 無狀態、多活 | 所有實例同時服務，由 LB 分流；任一掛掉 LB 健康檢查踢除 |
| etcd | Raft 共識 | 一個 leader，寫入需過半確認；leader 掛掉約 1–2 秒內重選 |
| kube-scheduler | Leader Election（Lease 物件） | 多實例只有一個 active，其餘 standby；切換約 15 秒（`leaseDuration`） |
| kube-controller-manager | 同上 | 同上 |
| CoreDNS | Deployment 多副本 | 見 2.7 |
| kube-proxy / CNI | DaemonSet | 每節點各自獨立，無單點 |

```bash
# 查看目前 leader
kubectl get lease -n kube-system kube-scheduler kube-controller-manager
```

### 2.5 工作負載 HA

Control Plane 掛掉時**既有 Pod 不受影響**（kubelet 與 containerd 獨立運作），但無法建立新 Pod 或故障轉移。反過來說，工作負載的 HA 主要靠以下設計，與 Control Plane 是否 HA 無關：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3                                   # ① 至少 2，建議 3（滾動更新時仍有 2 個）
  strategy:
    rollingUpdate:
      maxUnavailable: 0                         # ② 更新期間不減少可用副本
      maxSurge: 1
  template:
    spec:
      priorityClassName: business-critical      # ③ 資源不足時優先保留
      topologySpreadConstraints:                # ④ 平均分散到不同節點 / 可用區
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: web }
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: web }
      terminationGracePeriodSeconds: 60         # ⑤ 給應用時間處理完在途請求
      containers:
        - name: web
          image: myapp:1.0
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 5"]  # ⑥ 等 Endpoint 移除傳播到所有 kube-proxy 再關閉
          readinessProbe:                       # ⑦ 未就緒不收流量
            httpGet: { path: /ready, port: 8080 }
            periodSeconds: 5
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits: { memory: 256Mi }
---
apiVersion: policy/v1
kind: PodDisruptionBudget                       # ⑧ drain / 升級時保證最低可用數
metadata:
  name: web-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels: { app: web }
```

> **為什麼要 `preStop sleep`？** Pod 被刪除時，「從 Endpoints 移除」與「送 SIGTERM 給容器」是**平行**發生的。kube-proxy 更新 iptables 需要幾秒，這段時間新連線仍會被送到正在關閉的 Pod。sleep 幾秒讓規則先更新完，是零停機滾動更新的關鍵細節。

**StatefulSet 的額外考量：** Pod 有身分（`web-0`），節點失聯時 Kubernetes **不會**自動在其他節點重建（避免腦裂造成兩個 `web-0` 同時寫同一份資料）。需要 (a) 確認節點確實死亡後手動 `kubectl delete pod web-0 --force`，或 (b) 部署節點隔離（fencing）機制，或 (c) 使用 Operator（如 CloudNativePG、Strimzi）處理故障轉移。

### 2.6 節點故障處理時序

理解預設時序，才能判斷「多久會自動恢復」與「要不要調快」：

```
T+0s     節點斷電 / 網路中斷
T+10s    kubelet 停止更新 Node Lease（正常每 10s 一次）
T+40s    kube-controller-manager 判定 NotReady（node-monitor-grace-period）
         → 自動加上 taint：node.kubernetes.io/unreachable:NoExecute
T+40s    Deployment 的 Pod 開始倒數 tolerationSeconds（預設 300s）
T+340s   Pod 被驅逐（狀態變 Terminating），ReplicaSet 在其他節點建新 Pod
T+340s + 映像拉取 + 啟動時間 → 服務恢復

StatefulSet Pod：停在 Terminating，不會自動重建（見 2.5）
使用 RWO PV 的 Pod：新 Pod 卡在 ContainerCreating，等原節點的 VolumeAttachment 逾時（約 6 分鐘）
```

**加速方式**（對延遲敏感的服務）：

```yaml
# Pod spec：把 300s 縮短到 30s
tolerations:
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
```

或全域調整 KCM 的 `--node-monitor-grace-period`（不建議低於 20s，網路抖動會造成誤判）。

**優雅關機（計畫性維護）：** 啟用 kubelet Graceful Node Shutdown，讓節點收到關機訊號時先依序終止 Pod：

```yaml
# KubeletConfiguration
shutdownGracePeriod: 60s
shutdownGracePeriodCriticalPods: 20s
```

計畫性維護仍應先 `kubectl drain`（見 CKA-Q4）。

### 2.7 入口與 DNS 的 HA

| 元件 | 預設狀態 | HA 做法 |
|------|---------|--------|
| CoreDNS | 2 副本，**可能在同一節點** | 加 `podAntiAffinity`（`kubectl edit deploy coredns -n kube-system`），或改為 DaemonSet；搭配 NodeLocal DNSCache |
| Ingress Controller | 1 副本（多數 Helm chart 預設） | ≥ 2 副本 + 反親和 + PDB，或以 DaemonSet 跑在專用 ingress 節點 |
| MetalLB L2 模式 | 單一節點回應 ARP | 節點掛掉時由其他 speaker 接手（約 10 秒，依 memberlist 偵測）；流量集中在一個節點，非真正負載平衡 |
| MetalLB BGP 模式 | 多節點同時宣告 | 路由器 ECMP 分流，故障轉移取決於 BGP timer（可調至秒級） |
| 外部 DNS | — | 對外網域使用多 A 記錄或 GSLB；TTL 縮短到 60s 以內加快切換 |

```bash
# CoreDNS 反親和 patch
kubectl patch deploy coredns -n kube-system --type=merge -p '{
  "spec": {"template": {"spec": {"affinity": {"podAntiAffinity": {
    "requiredDuringSchedulingIgnoredDuringExecution": [{
      "labelSelector": {"matchLabels": {"k8s-app": "kube-dns"}},
      "topologyKey": "kubernetes.io/hostname"}]}}}}}}'
```

### 2.8 儲存 HA

| 情境 | 問題 | 對策 |
|------|------|------|
| RWO 磁碟（雲端 EBS/PD、iSCSI） | 節點失聯時磁碟仍附掛在舊節點，新 Pod 無法掛載 | 接受約 6 分鐘的 detach 逾時；或使用節點 fencing；或改用複製型儲存 |
| 單副本儲存（NFS 單機、hostPath） | 儲存節點本身是單點 | NFS 用 DRBD / 儲存設備的 HA；或改 Longhorn / Ceph |
| Longhorn | — | 每個 Volume 預設 3 副本分散在不同節點，節點掛掉自動用其他副本；設定 `replica-zone-soft-anti-affinity` 跨區 |
| Rook-Ceph | — | CRUSH map 依故障域（host / rack / zone）分散資料；OSD ≥ 3 節點 |
| 資料庫 | 儲存層 HA ≠ 資料庫 HA | 用資料庫自身複製（PostgreSQL streaming replication、MySQL Group Replication）+ Operator 處理 failover，儲存層只需 RWO |

### 2.9 多可用區與多叢集

#### 單叢集跨可用區

- 節點打上 `topology.kubernetes.io/zone` 標籤（雲端自動；地端手動）。
- **Control Plane 需 3 個區**：2 個區的話，一區失聯時 etcd 可能失去 quorum（3 成員配置 2+1，失去 2 那區就掛）。
- etcd 成員間 RTT 應 **< 10ms**；跨城市（> 30ms）不建議單叢集跨區，改用多叢集。
- 工作負載用 `topologySpreadConstraints` 跨區分散（見 2.5）。
- 儲存需支援跨區（雲端 regional disk；Longhorn zone anti-affinity）。

#### 多叢集

```
                    ┌─────────────────────────┐
                    │  Global LB / DNS (GSLB)  │
                    │  健康檢查 + 權重 / 就近    │
                    └─────┬──────────────┬─────┘
                          │              │
              ┌───────────▼──┐     ┌─────▼────────┐
              │ 叢集 A（台北）│     │ 叢集 B（高雄） │
              │ 完整 Control │     │ 完整 Control  │
              │ Plane + 工作 │     │ Plane + 工作  │
              └───────┬──────┘     └──────┬───────┘
                      │                   │
                      └──── GitOps ───────┘   ← 同一份 Git 定義同步部署到兩邊
                      └──── 資料複製 ─────┘   ← DB 跨叢集複製 / 物件儲存跨區複製
```

| 模式 | 說明 | 適用 |
|------|------|------|
| Active-Passive | B 叢集平時閒置或只跑低優先工作，A 掛掉時 DNS 切換 | RTO 分鐘級可接受、成本敏感 |
| Active-Active | 兩邊同時服務，GSLB 分流 | 需要秒級 RTO；資料層需支援多主或明確分區 |
| 叢集聯邦（Karmada、Liqo、Cluster API） | 統一管理多叢集的部署與排程 | 叢集數 > 3 |

**多叢集的關鍵不是 Kubernetes，而是資料。** 無狀態服務靠 GitOps 就能兩邊一致；有狀態服務需要資料庫層級的跨站複製與明確的切換程序。

### 2.10 HA 檢核表

安裝完成後逐項確認：

- [ ] `--control-plane-endpoint` 指向 VIP / DNS，而非單一節點 IP
- [ ] 3 個 Control Plane 分散在不同實體主機 / 機櫃 / 可用區
- [ ] etcd 使用獨立 SSD；`etcdctl endpoint health --cluster` 全部 healthy
- [ ] 關閉任一 Control Plane，`kubectl get nodes` 仍可用（VIP 漂移 < 10 秒）
- [ ] CoreDNS ≥ 2 副本且在不同節點
- [ ] Ingress Controller ≥ 2 副本且在不同節點，有 PDB
- [ ] 所有正式服務 `replicas ≥ 2`、有 `topologySpreadConstraints` 或反親和、有 PDB、有 readinessProbe
- [ ] 關鍵服務有 `PriorityClass`
- [ ] StatefulSet 有明確的節點故障處理程序（手動或 Operator）
- [ ] 儲存層有副本或後端 HA
- [ ] 節點資源 request 總和 < 80%，確保 N+1 容量
- [ ] 已實際演練：拔一台 Worker、拔一台 Control Plane、拔儲存節點

---

## 三、備份

HA 保護的是**硬體故障**；備份保護的是**邏輯錯誤**（誤刪、錯誤設定、勒索軟體、升級失敗）。HA 叢集會忠實地把 `kubectl delete ns production` 複製到三個 etcd 成員。

### 3.1 要備份什麼

| 層 | 內容 | 位置 | 備份方式 | 重要性 |
|----|------|------|---------|-------|
| **叢集狀態** | 所有 Kubernetes 物件（Deployment、Secret、ConfigMap、RBAC…） | etcd | `etcdctl snapshot save` | ★★★ |
| **PKI 憑證** | CA、apiserver、etcd、front-proxy 憑證與金鑰 | `/etc/kubernetes/pki/` | tar 打包（**含私鑰，需加密存放**） | ★★★ 遺失 CA = 所有節點需重新加入 |
| **kubeadm 設定** | 初始化參數 | `kubeadm-config` ConfigMap（在 etcd 內）+ 原始 `kubeadm-config.yaml` | Git | ★★★ |
| **Static Pod manifests** | apiserver / etcd / scheduler / KCM 的啟動參數 | `/etc/kubernetes/manifests/` | tar | ★★ 可由 kubeadm 重新產生，但手動修改（audit、encryption）會遺失 |
| **加密設定** | `EncryptionConfiguration`、audit policy | `/etc/kubernetes/enc/`、`/etc/kubernetes/audit/` | tar（**加密金鑰遺失 = Secret 永久無法解密**） | ★★★ |
| **CNI 設定** | Flannel / Calico 設定 | 在 etcd 內（ConfigMap）+ `/etc/cni/net.d/` | 隨 etcd | ★ |
| **應用資料** | 資料庫、上傳檔案 | PV | Velero + CSI Snapshot / 應用層 dump | ★★★ |
| **映像檔** | 私有 registry 內容 | Harbor / registry 儲存 | registry 自身的複製 / 儲存快照 | ★★ |
| **宣告式來源** | 所有 YAML / Helm values | Git | Git 本身的備份（GitHub / GitLab） | ★★★ 最終真相來源 |

> **etcd 快照包含 Secret 明文**（除非啟用靜態加密）。備份檔的存取控制等同於 cluster-admin 權限。

### 3.2 etcd 備份

CKA-Q5 示範了手動備份指令；正式環境需要**自動化、驗證、異地存放、保留策略**四件事。

#### 備份腳本

```bash
sudo tee /usr/local/bin/etcd-backup.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR=/var/backups/etcd
RETENTION_DAYS=14
REMOTE=s3://my-bucket/etcd-backups/$(hostname)   # 或 NFS 路徑、rsync 目標
TS=$(date +%Y%m%d-%H%M%S)
SNAP=$BACKUP_DIR/etcd-$TS.db

export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key

mkdir -p "$BACKUP_DIR"

# 1. 快照
etcdctl snapshot save "$SNAP"

# 2. 驗證：能讀出 hash / revision / key 數代表檔案完整
etcdctl snapshot status "$SNAP" --write-out=table

# 3. 一併備份 PKI 與 manifests（加密：金鑰只放在備份主機）
tar -czf "$BACKUP_DIR/k8s-config-$TS.tar.gz" \
    /etc/kubernetes/pki /etc/kubernetes/manifests \
    /etc/kubernetes/*.conf 2>/dev/null
gpg --batch --yes --symmetric --cipher-algo AES256 \
    --passphrase-file /root/.backup-passphrase \
    "$BACKUP_DIR/k8s-config-$TS.tar.gz"
rm -f "$BACKUP_DIR/k8s-config-$TS.tar.gz"

# 4. 異地複製（3-2-1 原則：3 份、2 種媒體、1 份異地）
aws s3 cp "$SNAP" "$REMOTE/" --only-show-errors
aws s3 cp "$BACKUP_DIR/k8s-config-$TS.tar.gz.gpg" "$REMOTE/" --only-show-errors

# 5. 本機保留策略
find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -delete

echo "etcd backup OK: $SNAP ($(du -h "$SNAP" | cut -f1))"
SCRIPT
sudo chmod 700 /usr/local/bin/etcd-backup.sh
```

#### 排程（systemd timer，比 CronJob 可靠：不依賴叢集本身正常）

```bash
sudo tee /etc/systemd/system/etcd-backup.service <<'UNIT'
[Unit]
Description=etcd snapshot backup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/etcd-backup.sh
UNIT

sudo tee /etc/systemd/system/etcd-backup.timer <<'UNIT'
[Unit]
Description=Run etcd backup every hour
[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true
[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now etcd-backup.timer
sudo systemctl list-timers etcd-backup.timer
```

| 決策 | 建議 |
|------|------|
| 頻率 | 每小時（RPO = 1 小時）；變更頻繁的叢集可 15 分鐘。快照通常 < 100 MB，成本很低 |
| 在哪台執行 | Stacked HA：任一台 Control Plane 即可（資料一致），建議每台都跑、錯開時間，避免單點 |
| 保留 | 本機 14 天 + 異地 90 天 + 每月一份長期保存 |
| 監控 | timer 失敗要告警（`systemctl status etcd-backup.service`、或推送指標到 Pushgateway） |
| 升級前 | 手動額外做一份，命名標註版本 |

### 3.3 應用資料備份：Velero

Velero 是 Kubernetes 應用層備份的事實標準：備份 **Kubernetes 物件（依 namespace / label 篩選）+ PV 資料**，可還原到同一或不同叢集，也常用於叢集遷移。

#### 安裝（以 MinIO 作為 S3 相容後端為例）

```bash
# 1. 準備 S3 憑證
cat > credentials-velero <<'CRED'
[default]
aws_access_key_id = minio
aws_secret_access_key = minio123
CRED

# 2. 安裝 CLI
VELERO_VER=v1.15.2   # 請確認與 K8s 版本相容的最新版
curl -fsSL https://github.com/vmware-tanzu/velero/releases/download/$VELERO_VER/velero-$VELERO_VER-linux-amd64.tar.gz | \
  sudo tar -xzf - -C /usr/local/bin --strip-components=1 velero-$VELERO_VER-linux-amd64/velero

# 3. 安裝到叢集
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.11.0 \
  --bucket velero \
  --secret-file ./credentials-velero \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://minio.minio.svc:9000

kubectl get pods -n velero
velero backup-location get     # PHASE 應為 Available
```

| 選項 | 說明 |
|------|------|
| `--use-node-agent` + `--default-volumes-to-fs-backup` | 用 Kopia 做**檔案層級**備份，任何 PV 類型都適用（含本指南的 hostPath / local PV），但屬 crash-consistent |
| `--features=EnableCSI` + VolumeSnapshotClass | 用 **CSI 快照**，速度快、空間效率高，需 CSI driver 支援快照（Longhorn、Ceph、雲端磁碟） |

#### 使用

```bash
# 手動備份整個 namespace
velero backup create prod-$(date +%Y%m%d) --include-namespaces production --wait
velero backup describe prod-20260831 --details

# 排程：每天 02:00，保留 30 天
velero schedule create prod-daily \
  --schedule="0 2 * * *" \
  --include-namespaces production \
  --ttl 720h

# 排程：每小時備份全叢集物件（不含 PV 資料，秒級完成）
velero schedule create cluster-objects-hourly \
  --schedule="@hourly" \
  --snapshot-volumes=false \
  --default-volumes-to-fs-backup=false \
  --ttl 168h

# 還原（誤刪 namespace 的救援）
velero restore create --from-backup prod-20260831 --wait
velero restore describe <restore-name>

# 還原到不同 namespace（用於驗證備份或建立測試副本）
velero restore create --from-backup prod-20260831 \
  --namespace-mappings production:production-restore-test
```

#### 應用一致性：pre/post hooks

檔案層級備份對執行中的資料庫是 crash-consistent（相當於斷電後的狀態）。要 application-consistent，需要在備份前凍結或 dump：

```yaml
# Pod annotation：備份前 flush 並鎖表，備份後解鎖
metadata:
  annotations:
    pre.hook.backup.velero.io/container: mysql
    pre.hook.backup.velero.io/command: '["/bin/sh","-c","mysql -e \"FLUSH TABLES WITH READ LOCK; SYSTEM sleep 30;\" &"]'
    pre.hook.backup.velero.io/timeout: 60s
    post.hook.backup.velero.io/container: mysql
    post.hook.backup.velero.io/command: '["/bin/sh","-c","mysql -e \"UNLOCK TABLES\""]'
```

更穩健的做法：資料庫用**自身工具**（`pg_dump`、`mysqldump`、`mongodump`、`etcdctl snapshot`）以 CronJob 定期 dump 到物件儲存，Velero 負責 Kubernetes 物件與非資料庫的 PV。

### 3.4 CSI VolumeSnapshot

支援快照的 CSI driver 可直接以 Kubernetes 原生物件做磁碟快照，不經過 Velero：

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snap
driver: driver.longhorn.io
deletionPolicy: Delete
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: mysql-data-snap-20260831
  namespace: production
spec:
  volumeSnapshotClassName: longhorn-snap
  source:
    persistentVolumeClaimName: mysql-data
---
# 從快照建立新 PVC（還原或複製）
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-data-restored
  namespace: production
spec:
  storageClassName: longhorn
  dataSource:
    name: mysql-data-snap-20260831
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
```

> 快照通常存在**同一個儲存系統**內，儲存系統整個毀掉時快照也沒了。快照是快速回滾工具，不是異地備份；需搭配 Velero / 儲存系統的異地複製。

### 3.5 GitOps 作為備份的第一道防線

若所有資源定義都在 Git 且由 Argo CD / Flux 同步，則：

- 誤刪 Deployment / ConfigMap → 下一次同步（或手動 sync）自動恢復，**不需要動用備份**。
- 重建叢集 → 指向同一個 Git repo，數分鐘內所有無狀態服務就位。
- Git 歷史本身就是變更稽核紀錄。

Git 無法涵蓋的部分才需要 etcd / Velero：Secret（除非用 Sealed Secrets / External Secrets）、PV 資料、由 Controller 動態產生的物件（cert-manager 的憑證、Operator 建立的資源）、以及 `kubectl edit` 手動改過但沒回寫 Git 的東西（這是應該被禁止的）。

### 3.6 備份策略設計

| 項目 | 決策依據 | 範例 |
|------|---------|------|
| **RPO**（可遺失多少資料） | 業務對資料遺失的容忍度 | etcd 1 小時；資料庫 15 分鐘（WAL 歸檔）；檔案 24 小時 |
| **RTO**（多久要恢復） | SLA | 見第四節各情境 |
| **3-2-1 原則** | 3 份副本、2 種媒體、1 份異地 | 本機磁碟 + 物件儲存 + 異地物件儲存（跨區複製） |
| **加密** | 備份含 Secret 與私鑰 | 靜態加密（S3 SSE / gpg）+ 傳輸加密；金鑰與備份分開保管 |
| **不可變性** | 防勒索軟體刪除備份 | S3 Object Lock / 版本控制；備份帳號只有寫入權無刪除權 |
| **保留** | 合規要求 + 儲存成本 | 每小時保留 2 天、每日 30 天、每週 3 個月、每月 1 年 |
| **驗證** | 沒還原過的備份不算備份 | 見 3.7 |

### 3.7 備份驗證

| 層級 | 頻率 | 做法 |
|------|------|------|
| 檔案完整性 | 每次備份 | `etcdctl snapshot status`；Velero `backup describe` PHASE 為 Completed |
| 物件層還原 | 每週自動 | Velero 還原到 `*-restore-test` namespace，比對物件數量後刪除 |
| etcd 還原 | 每月 | 在**測試叢集**（或 Vagrant 環境）用正式備份執行 4.3-A 流程，確認 `kubectl get all -A` 正常 |
| 完整 DR 演練 | 每季 / 每半年 | 依第四節 runbook 從零重建，量測實際 RTO |

---

## 四、災難復原

### 4.1 災難情境分類

| 等級 | 情境 | 自動恢復？ | 主要手段 | 典型 RTO |
|------|------|:---------:|---------|---------|
| L0 | 單一 Pod 崩潰 | ✅ | ReplicaSet 重建 | 秒 |
| L1 | 單一 Worker 節點故障 | ✅ | 驅逐 + 重排程（2.6 時序） | 5–10 分鐘 |
| L2 | 單一 Control Plane 故障（HA 叢集） | ✅ | VIP 漂移、Leader Election | 秒 |
| L2 | 唯一 Control Plane 故障（非 HA） | ❌ | 修復節點或 etcd 還原（4.3-A） | 30 分鐘–數小時 |
| L3 | etcd 失去 quorum（HA 叢集 2/3 掛） | ❌ | 4.3-B | 30 分鐘–1 小時 |
| L3 | 憑證過期 | ❌ | 4.3-D | 15–30 分鐘 |
| L4 | 邏輯錯誤：誤刪 namespace / 錯誤部署 | ❌ | GitOps 同步、Velero 還原（4.3-E） | 5–30 分鐘 |
| L4 | 資料損毀（資料庫、PV） | ❌ | 應用層備份還原 | 依資料量 |
| L5 | 叢集完全毀損（儲存全毀、升級失敗無法回復） | ❌ | 全叢集重建（4.3-F） | 1–4 小時 |
| L6 | 站點級災難（機房失火、區域斷網） | ❌ | 多站點切換（4.3-H） | 15 分鐘–數小時 |

### 4.2 RPO / RTO 與方案對照

```
             RTO（恢復時間）
   數小時 ┤  單站 + 每日備份              ← 最低成本
          │
   1 小時 ┤  單站 + 每小時 etcd 快照 + Velero
          │
   分鐘級 ┤  HA 叢集 + 自動化重建腳本 + GitOps
          │
   秒級   ┤  多站 Active-Active + 資料同步複製  ← 最高成本
          └────┬──────────┬──────────┬──────────┬────
             秒級       分鐘級      1 小時     24 小時   RPO（資料遺失）
```

先由業務單位定出各系統的 RPO/RTO（需求分析章節第九節），再反推需要哪一層方案。**不是所有系統都需要秒級**；把 80% 的預算花在 20% 真正關鍵的服務上。

### 4.3 情境演練與 Runbook

以下每個情境都可在本指南的 Vagrant 環境實際演練（`vagrant snapshot save` 可先存檔以便反覆練習）。

#### A. 單一 Control Plane：從 etcd 快照還原

適用：etcd 資料損毀、需要回到某個時間點、誤刪大量資源且無 Velero。

```bash
# 0. 確認快照可用
export ETCDCTL_API=3
sudo etcdctl snapshot status /var/backups/etcd/etcd-20260831-020000.db --write-out=table

# 1. 停止 apiserver 與 etcd（移走 static Pod manifest，kubelet 會自動停掉它們）
sudo mkdir -p /root/manifests-bak
sudo mv /etc/kubernetes/manifests/{kube-apiserver,etcd}.yaml /root/manifests-bak/
sleep 20
sudo crictl ps | grep -E "etcd|kube-apiserver"   # 應為空

# 2. 保留舊資料目錄（萬一還原失敗可回退）
sudo mv /var/lib/etcd /var/lib/etcd.broken-$(date +%s)

# 3. 還原到原資料目錄（單節點可直接還原；--name / --initial-* 需與 etcd.yaml 一致）
sudo etcdctl snapshot restore /var/backups/etcd/etcd-20260831-020000.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-master \
  --initial-cluster=k8s-master=https://192.168.56.10:2380 \
  --initial-advertise-peer-urls=https://192.168.56.10:2380
# 註：若 etcd.yaml 的 --name 與 --initial-cluster 值不同，請以 etcd.yaml 為準；
#     不加這些參數也能還原（會用 default），但 member 名稱會與 manifest 不一致。

# 4. 恢復 static Pod
sudo mv /root/manifests-bak/*.yaml /etc/kubernetes/manifests/
sleep 30

# 5. 驗證
kubectl get nodes
kubectl get pods -A
sudo -E etcdctl endpoint status --write-out=table   # 使用 1.3 節的環境變數

# 6. 還原後的清理
#    - 快照時間點之後建立的 Pod 在 etcd 中不存在，但容器仍在節點上跑 → kubelet 會自動清除
#    - 快照時間點之後刪除的 Pod 在 etcd 中「復活」→ 會被重新建立
#    - Worker 節點的 kubelet 可能需要重啟以重新同步：sudo systemctl restart kubelet
```

> **與 CKA-Q5 的差異：** 考試流程用 `--data-dir=/var/lib/etcd-restore` 並改 manifest 路徑，是為了避免動到原資料。正式環境習慣還原到原路徑並保留舊目錄，避免 manifest 與備份腳本路徑不一致的長期混亂。兩者都正確。

#### B. HA 叢集：etcd 失去 quorum

情境：3 個 Control Plane 中 cp2、cp3 同時損毀（例如兩台在同一台實體機上），只剩 cp1。etcd 沒有 quorum，**叢集唯讀**：既有 Pod 照跑，但無法做任何變更。

```bash
# ===== 在唯一存活的 cp1 上 =====

# 1. 確認狀態：只有 cp1 healthy，且 etcd 拒絕寫入
sudo -E etcdctl endpoint health --cluster
sudo -E etcdctl member list --write-out=table

# 2. 從 cp1 自己的資料做一份快照（比排程備份新）
sudo -E etcdctl snapshot save /var/backups/etcd/pre-recovery.db

# 3. 停止 cp1 的 apiserver 與 etcd
sudo mv /etc/kubernetes/manifests/{kube-apiserver,etcd}.yaml /root/
sleep 20

# 4. 用快照重建為「單成員叢集」（--initial-cluster 只列自己，這會重寫成員資訊，丟棄 cp2/cp3）
sudo mv /var/lib/etcd /var/lib/etcd.broken-$(date +%s)
sudo -E etcdctl snapshot restore /var/backups/etcd/pre-recovery.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-cp1 \
  --initial-cluster=k8s-cp1=https://192.168.56.10:2380 \
  --initial-advertise-peer-urls=https://192.168.56.10:2380 \
  --initial-cluster-token=etcd-recovered

# 5. 啟動；此時 etcd 是 1 成員叢集，有 quorum，可寫入
sudo mv /root/{kube-apiserver,etcd}.yaml /etc/kubernetes/manifests/
sleep 30
sudo -E etcdctl member list --write-out=table    # 只剩 k8s-cp1
kubectl get nodes                                 # cp2、cp3 顯示 NotReady

# 6. 清除失效節點的 Node 物件
kubectl delete node k8s-cp2 k8s-cp3

# ===== 修復或重建 cp2、cp3 =====

# 7. 在 cp2 / cp3 上完全清除舊狀態
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /etc/cni/net.d

# 8. 在 cp1 產生新的加入憑證與 token
sudo kubeadm init phase upload-certs --upload-certs        # 取得 certificate-key
kubeadm token create --print-join-command                  # 取得 join 指令

# 9. cp2 / cp3 以 Control Plane 身分重新加入（kubeadm 會自動 member add 並同步資料）
sudo kubeadm join 192.168.56.100:6443 --token ... --discovery-token-ca-cert-hash sha256:... \
  --control-plane --certificate-key ... --apiserver-advertise-address 192.168.56.11

# 10. 驗證回到 3 成員
sudo -E etcdctl member list --write-out=table
sudo -E etcdctl endpoint health --cluster
```

若 **三台全部損毀**但有排程備份：在新機器上依 2.2 步驟建叢集到「步驟 3 init 完成」，然後執行 A 流程用備份覆蓋 cp1 的 etcd，再加入 cp2/cp3。前提是 **PKI 憑證有備份**（否則所有 Worker 都要重新 join）。

#### C. 移除並替換單一故障的 Control Plane（仍有 quorum）

3 台中掛 1 台，叢集正常運作，但需要補回第三台：

```bash
# 1. 在健康的 cp 上，找出並移除失效的 etcd 成員（否則新節點 join 時 kubeadm 會報 unhealthy member）
sudo -E etcdctl member list --write-out=table
sudo -E etcdctl member remove <失效成員的 ID>

# 2. 刪除 Node 物件
kubectl delete node k8s-cp3

# 3. 新機器（或修復後的 cp3）執行 kubeadm reset，再依 B 的步驟 8–9 重新加入
```

**別在 etcd 只剩 2 成員時做任何有風險的維護**（升級、重啟）：此時再掛 1 台就失去 quorum。先補回第三台。

#### D. 憑證過期

kubeadm 核發的元件憑證有效期 **1 年**，CA **10 年**。`kubeadm upgrade` 會自動更新憑證，一年內至少升級一次的叢集不會遇到；長期不升級的叢集常在滿一年當天突然「所有 kubectl 指令 x509 錯誤」。

```bash
# 預防：加入監控，到期前 30 天告警
sudo kubeadm certs check-expiration

# 更新所有憑證（在每台 Control Plane 執行）
sudo kubeadm certs renew all

# 憑證更新後必須重啟 static Pod 才會載入新憑證
sudo mv /etc/kubernetes/manifests/*.yaml /root/manifests-tmp/ && sleep 20 && \
sudo mv /root/manifests-tmp/*.yaml /etc/kubernetes/manifests/

# 更新 kubectl 使用的 admin.conf
sudo cp /etc/kubernetes/admin.conf ~/.kube/config

# kubelet 客戶端憑證預設自動輪替（rotateCertificates: true），不需處理；
# 若 kubelet 憑證已過期且無法自動輪替，該節點需重新 join
```

**CA 過期**（10 年）：無法用 `certs renew` 處理，需要規劃 CA 輪替（官方文件「Manual Rotation of CA Certificates」），流程涉及所有節點，應在到期前一年開始準備。

#### E. 誤刪 namespace / 錯誤部署

依有無 GitOps 與 Velero 選擇最快路徑：

| 情況 | 恢復方式 | RTO |
|------|---------|-----|
| 只刪了無狀態資源，有 GitOps | Argo CD / Flux 手動 sync 或等自動同步 | 1–5 分鐘 |
| 刪了含 PV 的 namespace，有 Velero | `velero restore create --from-backup <最近備份> --include-namespaces production` | 5–30 分鐘（依資料量） |
| 刪了含 PV 的 namespace，PV reclaimPolicy 為 `Retain` | PV 變 Released，資料還在：清除 `claimRef` 後重新建立 PVC 綁定（見存儲章節） | 10 分鐘 |
| 錯誤的 Deployment 版本 | `kubectl rollout undo deploy/<name>`（見 CKAD-Q6） | 1 分鐘 |
| 錯誤的 ConfigMap 導致全面故障，無 GitOps 無 Velero | etcd 快照還原（A）— **會讓整個叢集回到快照時間點**，影響所有 namespace | 30 分鐘+ |

> etcd 快照還原是「時光機」而非「復原鍵」：所有 namespace 一起回到過去。只在別無選擇時使用；這正是為什麼 Velero 與 GitOps 值得在一開始就部署。

#### F. 全叢集重建

適用：升級失敗且無法回復、儲存全毀、或要遷移到新硬體。

**路徑 1：保留身分（用 PKI 備份 + etcd 快照）**

```
1. 新 Control Plane 節點完成共同設定
2. 還原 /etc/kubernetes/pki（從備份 tar 解密）到新節點
3. kubeadm init --config kubeadm-config.yaml（與原叢集相同參數）
   → kubeadm 偵測到既有 CA 會沿用，不重新產生
4. 依 A 流程用 etcd 快照覆蓋
5. 既有 Worker 因 CA 相同，重啟 kubelet 後自動重新連上（apiserver 位址不變的前提下）
```

RTO 約 30–60 分鐘；優點是 Worker 不需重新 join、所有 ServiceAccount token 與 Secret 有效。

**路徑 2：全新叢集 + GitOps + Velero**

```
1. 用 kubeadm-config.yaml 建全新叢集（含新 CA）
2. 所有 Worker 重新 join
3. 安裝 CNI、儲存、Velero（指向同一個備份 bucket）
4. Argo CD / Flux 指向 Git repo → 無狀態服務自動部署
5. velero restore 還原有狀態服務的 PV 資料
```

RTO 約 1–4 小時；優點是乾淨、可順便升級版本；缺點是所有憑證與 token 更新，外部整合（CI/CD 的 kubeconfig、OIDC）需重新設定。

**兩條路徑都應寫成腳本並定期在測試環境跑一遍。** 本指南的 `Vagrantfile` + `scripts/` 就是路徑 2 的最小可行版本。

#### G. 大量 Worker 失聯 / 網路分割

情境：交換器故障，一半 Worker 與 Control Plane 斷線。

```
Control Plane 視角：
  T+40s   一半節點 NotReady，加 unreachable taint
  T+340s  開始驅逐這些節點上的 Pod，在剩餘節點重建
          → 若剩餘節點容量不足（沒有 N+1 餘裕），新 Pod Pending

失聯 Worker 視角：
  Pod 仍在跑（kubelet 獨立運作），但：
  - Service 的 Endpoints 已被移除 → 沒有新流量進來
  - 無法拉新映像、無法回報狀態
  - 若 Pod 掛掉，kubelet 會依 restartPolicy 在本機重啟

網路恢復後：
  - 節點回報 Ready，taint 移除
  - 被驅逐的 Pod 在舊節點上會被 kubelet 清除（因 etcd 中已無此 Pod）
  - 短時間內同一服務可能有「新舊兩批 Pod」同時服務 → 對有狀態服務是腦裂風險
```

對策：Control Plane 與 Worker 之間的網路路徑要有冗餘（雙上聯）；有狀態服務用 Lease / 分散式鎖確認唯一性；`topologySpreadConstraints` 跨機櫃分散。

#### H. 站點級災難

```
1. 確認災難範圍與預估修復時間（決定是否啟動 DR，不要因 5 分鐘網路抖動就切換）
2. 宣告 DR 啟動，通知相關單位（預先定義決策者與通報鏈）
3. 確認備援站點資料狀態：最後一次同步時間 = 實際 RPO
4. 備援站點提升為主：資料庫 promote replica、物件儲存切換
5. DNS / GSLB 切換流量到備援站點
6. 驗證核心業務流程
7. 事後：主站修復後的資料回流（fail-back）計畫 — 通常比切換更複雜
```

### 4.4 DR 演練計畫

沒有演練過的 DR 計畫在真正災難時幾乎一定會失敗——不是技術不對，是文件過時、密碼找不到、負責人休假。

| 演練 | 頻率 | 方式 | 驗證項目 |
|------|------|------|---------|
| etcd 還原 | 每月 | 測試叢集 | 還原後 `kubectl get all -A` 與備份時一致 |
| Velero 還原 | 每週（自動） | 還原到 `*-restore-test` namespace | 物件數量、Pod 可啟動、資料抽樣比對 |
| Control Plane 故障 | 每季 | 正式 HA 叢集關掉一台 | VIP 漂移時間、無告警外的異常 |
| Worker 故障 | 每季 | 正式叢集 drain 或直接關機一台 | Pod 重排程時間、PDB 是否阻擋 |
| 全叢集重建 | 每半年 | 測試環境從零跑 4.3-F | 實際 RTO、文件缺漏 |
| 站點切換 | 每年 | 真實或桌面演練（tabletop） | 決策流程、通報鏈、fail-back |

演練後的產出：實測 RTO/RPO、發現的問題清單、runbook 更新。

**Runbook 範本（每個情境一份）：**

```markdown
# Runbook：<情境名稱，如「etcd 失去 quorum」>

- 最後更新 / 最後演練日期：
- 負責人（主 / 副）：
- 觸發條件（什麼徵兆代表是這個情境）：
- 影響範圍（哪些服務、使用者會受影響）：
- 預估 RTO / RPO：

## 前置檢查
- [ ] 確認徵兆符合（列出要看的指標 / 指令）
- [ ] 確認備份存在且可讀（指令）
- [ ] 通知（誰、怎麼通知）

## 步驟
1. （指令 + 預期輸出）
2. ...

## 驗證
- [ ] （指令 + 預期輸出）

## 回退
（步驟失敗時如何回到執行前狀態）

## 事後
- [ ] 事故報告
- [ ] 更新此 runbook
```

### 4.5 DR 檢核表

- [ ] 每個關鍵系統有書面 RPO / RTO，且經業務單位確認
- [ ] etcd 每小時快照，異地存放，已驗證可還原
- [ ] PKI 與加密設定已備份且加密存放，金鑰保管人明確
- [ ] 所有資源定義在 Git；`kubectl edit` 直接修改正式環境已被禁止或會被 GitOps 覆蓋
- [ ] Velero 排程運作中，`backup-location` 為 Available，最近一次還原測試通過
- [ ] 資料庫有應用層備份（dump / WAL 歸檔），非僅磁碟快照
- [ ] 憑證到期監控已設定（`kubeadm certs check-expiration` 或 Prometheus `certmanager_*` / 自訂 exporter）
- [ ] 4.3 每個情境都有 runbook，且一年內演練過
- [ ] 備份儲存有不可變保護（Object Lock），備份帳號無刪除權限
- [ ] DR 決策者與通報鏈已定義，聯絡方式不依賴叢集本身（別把 on-call 名單只放在叢集裡的 wiki）
- [ ] 重建叢集所需的一切（kubeadm-config.yaml、映像、Helm values、密碼保險箱）都可在**叢集完全消失**的情況下取得

---

## 五、設計決策建議

前面各節列出了選項與取捨；本節直接給出**「沒有特殊理由就這樣選」的預設建議**。依叢集規模分三個等級，每個決策附上理由，以及什麼情況下該改變主意。

### 5.1 決策矩陣（依規模）

| 決策項目 | 學習 / 開發<br>（1 CP + 1–3 Worker） | 小型正式<br>（3 CP + 3–20 Worker） | 大型正式<br>（3–5 CP + 20–500 Worker） |
|---------|:--:|:--:|:--:|
| **Control Plane 拓撲** | 單一 | 3 台 Stacked etcd | 3 台 Stacked（節點 < 200）或 3 CP + 3 External etcd |
| **`--control-plane-endpoint`** | 建議仍設 DNS 名稱 | **必須**：VIP 或 DNS | **必須**：LB DNS 名稱 |
| **VIP / LB** | 無 | kube-vip（ARP） | 雲端 LB；地端 kube-vip BGP 或 HAProxy + keepalived |
| **etcd 磁碟** | 共用 | 獨立 SSD | 獨立 NVMe；考慮 Events 分流 |
| **Pod CIDR** | 10.244.0.0/16 | /16（≤ 256 節點） | /14 或更大；`node-cidr-mask-size` 依 maxPods 調整 |
| **Service CIDR** | 10.96.0.0/12 | 預設 | 預設（已有 100 萬個 IP） |
| **CNI** | Flannel | Calico | Cilium（新建）/ Calico（團隊已熟悉） |
| **封裝模式** | VXLAN | 同 L2 用 host-gw / BGP，否則 VXLAN | 原生路由（BGP）或 Cilium eBPF |
| **kube-proxy 模式** | iptables | iptables；Service > 1,000 改 IPVS | IPVS；或 Cilium 取代 kube-proxy |
| **DNS** | CoreDNS 預設 | CoreDNS 反親和 + NodeLocal DNSCache | 同左 + `cluster-proportional-autoscaler` |
| **對外入口** | NodePort | MetalLB L2 + nginx Ingress（≥ 2 副本） | MetalLB BGP / 雲端 LB + Ingress 專用節點；新專案評估 Gateway API |
| **儲存** | hostPath / local-path | Longhorn（無外部儲存）或 NFS（有 NAS） | Rook-Ceph、企業 CSI、或雲端 CSI；多個 StorageClass 分級 |
| **資源保留** | 不設 | kubeReserved + systemReserved + evictionHard | 同左 + `cpuManagerPolicy: static`（延遲敏感節點） |
| **稽核日誌** | 關 | **開**（Metadata 等級 + Secret 排除 RequestResponse） | 開 + 送到 SIEM |
| **Secret 靜態加密** | 關 | **開**（aescbc / secretbox） | 開，KMS provider（雲端 KMS / Vault） |
| **身分驗證** | admin.conf | OIDC（Keycloak / Azure AD） | OIDC + 群組對應 RBAC |
| **Pod Security** | 無 | 全部 namespace `baseline`，敏感者 `restricted` | 同左 + OPA Gatekeeper / Kyverno 策略 |
| **監控** | metrics-server | kube-prometheus-stack | 同左 + Thanos / Mimir 長期儲存、多叢集匯總 |
| **日誌** | `kubectl logs` | Loki + Promtail | Loki / Elasticsearch 叢集、保留策略 |
| **etcd 備份** | 手動練習 | 每小時 systemd timer + 異地 | 同左 + 每台 CP 錯開執行 |
| **應用備份** | 無 | Velero（檔案層級）+ DB 原生 dump | Velero + CSI 快照 + DB 原生 + 異地複製 |
| **GitOps** | 可選 | Argo CD 或 Flux | 必須；多叢集用 ApplicationSet |
| **版本策略** | 最新 | 最新減一；每 6 個月升級 | 同左；先在 staging 叢集演練 |
| **DR 目標** | 無 | RPO 1h / RTO 1h（etcd 快照 + 重建腳本） | RPO 分鐘級 / RTO 分鐘級（多站點 Active-Passive 以上） |

### 5.2 關鍵決策的理由與取捨

以下是最常被問「為什麼」的十二個決策。

**1. 即使只有一台 Control Plane，也要設 `--control-plane-endpoint`**
- 選它：成本為零（一筆 DNS 記錄指向唯一那台），日後升級 HA 只需改 DNS。
- 不設的代價：憑證 SAN、所有節點的 kubeconfig 都綁死單一 IP；升級 HA 要重簽憑證並逐台修改。
- 何時例外：純拋棄式的實驗環境（如本指南 Vagrant）。

**2. Control Plane 選 3 台，不是 2 台也不是 5 台**
- 3 台：容忍 1 台故障，是 HA 的最低配置。
- 2 台：容錯能力與 1 台相同（quorum = 2，掛 1 台就失去 quorum），純粹多一個故障點。
- 5 台：容忍 2 台故障，但每次寫入要 3 台確認，延遲上升；只有節點數 > 500 或跨可用區部署才值得。

**3. Stacked etcd 優先於 External etcd**
- 選它：機器數減半、kubeadm 原生支援、憑證管理簡單。
- 何時改：Control Plane 節點 CPU / 磁碟 I/O 明顯被 etcd 拖累（`etcd_disk_wal_fsync` p99 因 apiserver 負載升高而惡化）、或安全政策要求 etcd 網路隔離。

**4. 地端 VIP 選 kube-vip，不選 HAProxy + keepalived**
- 選它：以 static Pod 形式跑在 Control Plane 上，無額外機器、無額外套件、設定只有一個 manifest；同時可提供 Service LoadBalancer。
- 不選的理由：HAProxy + keepalived 更成熟、可觀測性更好、可做更精細的健康檢查。
- 何時改：團隊已有 HAProxy 維運經驗；或需要對 apiserver 做 L7 級別的流量控制。

**5. CNI：Flannel（學習）→ Calico（一般正式）→ Cilium（新建大型）**
- Flannel：最簡單，但不支援 NetworkPolicy，正式環境幾乎必然會需要。
- Calico：NetworkPolicy + BGP 原生路由 + 成熟穩定，是「不會出錯」的正式環境選擇。
- Cilium：eBPF 帶來的效能、可觀測性（Hubble）、取代 kube-proxy 都是實質優勢，但學習曲線陡、核心版本要求高、除錯需要 eBPF 知識。
- 何時改：叢集規模 > 100 節點或需要 L7 policy → 值得投資 Cilium；團隊小、求穩 → Calico。

**6. kube-proxy 保持 iptables，直到 Service 超過 1,000 個**
- 選它：預設、最多人用、問題最容易搜到答案。
- 何時改：`kubectl get svc -A | wc -l` > 1,000，或觀察到 Endpoint 變更後生效延遲 > 數秒 → 切 IPVS。新建大型叢集用 Cilium 則直接取代 kube-proxy。

**7. 記憶體 request = limit；CPU 只設 request、limit 不設或設寬**
- 記憶體不可壓縮，超賣的後果是 OOM 殺錯 Pod；request = limit 讓行為可預測。
- CPU 可壓縮，CFS throttling 對延遲的傷害通常大於節點超載；不設 limit 讓閒置 CPU 被充分利用。
- 何時改：多租戶環境需要硬性隔離、或某個 Pod 曾經跑滿 CPU 影響鄰居 → 對該 Pod 設 limit = request × 2–4。

**8. 資料庫用 RWO 磁碟 + 資料庫自身複製，不依賴儲存層 HA**
- 儲存層複製（Longhorn / Ceph）保護的是磁碟壞掉；資料庫複製（PostgreSQL streaming、MySQL Group Replication）保護的是資料庫程序掛掉並提供讀寫分離。兩者互補，但若只能選一個，選資料庫層的。
- 用 Operator（CloudNativePG、Percona、Strimzi）處理 failover，不要自己寫。
- 避免 RWX：NFS 的鎖與效能問題會在最忙的時候出現；需要共享檔案時優先考慮物件儲存（S3 API）。

**9. 備份三層缺一不可：etcd 快照 + Velero + GitOps**
- etcd 快照：唯一能救回「叢集本身」（含 ServiceAccount token、Lease、動態產生的資源）的方法。
- Velero：唯一能做「只還原某個 namespace」的方法。
- GitOps：唯一能在「叢集完全消失」時快速重建的方法，且是變更稽核紀錄。
- 只做其中一層的常見後果：只有 etcd → 誤刪一個 namespace 要整個叢集時光倒流；只有 Velero → 叢集憑證壞了無法救；只有 GitOps → Secret 與 PV 資料沒了。

**10. 實施順序：GitOps → 監控 → etcd 備份 → Velero → 調優**
- GitOps 先做：越晚做，累積的「手動改過但沒進 Git」的漂移越多，遷移成本越高。
- 監控在調優之前：沒有指標的調優是猜測。
- Velero 在 etcd 備份之後：etcd 備份 10 分鐘可完成，先確保最基本的保護。
- 效能調優最後：多數叢集在合理的資源保留與 request/limit 設定下不需要進一步調優；等指標顯示瓶頸再動手。

**11. 稽核日誌與 Secret 加密從第一天開啟**
- 事後開啟稽核只需改 apiserver manifest，但事後開啟加密需要 `kubectl get secrets -A -o json | kubectl replace -f -` 重寫所有 Secret，且加密金鑰的備份流程要從此納入 DR。
- 合規稽核幾乎一定會問「從什麼時候開始有紀錄」。
- 何時例外：純學習環境。

**12. 版本選最新減一，每 6 個月升級一次**
- 最新版的 bug 由別人先踩；減一版仍有 ~10 個月支援期。
- 每年 3 個 minor 版本，每次只能升一個 minor；6 個月升一次剛好不會落後到超出支援視窗（3 個版本 ≈ 12 個月）。
- 升級也順便更新憑證，避開一年到期的地雷。
- 何時改：託管服務（EKS / GKE / AKS）有自己的版本節奏，跟隨即可。

### 5.3 反模式：常見的錯誤決策

| 反模式 | 後果 | 正確做法 |
|-------|------|---------|
| 2 台 Control Plane | 與 1 台容錯相同，多一個故障點 | 1 台或 3 台 |
| Pod / Service CIDR 與內網或 VPN 重疊 | 特定使用者連不到內部服務，極難排查 | 需求分析 5.1：三網段與所有既有網段確認不重疊 |
| etcd 與容器映像共用磁碟 | 映像拉取時 etcd fsync 延遲飆高，leader 反覆切換 | etcd 獨立 SSD |
| 只有 HA 沒有備份 | `kubectl delete ns` 被忠實複製到三個成員 | 3.1 三層備份 |
| 備份從未還原測試 | 需要時才發現快照損壞、密碼遺失、流程過時 | 3.7 定期驗證 |
| 所有 Pod 都設 CPU limit = request（追求 Guaranteed） | 大量 CFS throttling，延遲比不設 limit 更差 | 5.2 第 7 點 |
| liveness probe 檢查資料庫連線 | 資料庫慢 → 所有 Pod 被重啟 → 雪崩 | liveness 只檢查程序本身 |
| 用 `kubectl edit` 改正式環境 | Git 與實際狀態漂移；重建時遺失變更 | GitOps + RBAC 限制直接寫入 |
| Ingress Controller 單副本；CoreDNS 兩副本在同一節點 | 該節點掛掉 = 全站 502 / DNS 失效 | 2.7 反親和 + PDB |
| 忽略憑證到期 | 滿一年當天所有 kubectl 指令 x509 錯誤 | 4.3-D 監控 + 每年升級 |
| 正式資料放 `hostPath` | Pod 換節點資料就不見；節點磁碟壞了資料全丟 | 6.2 選擇有副本的儲存 |
| 不設 kubeReserved / systemReserved | Pod 吃光節點資源，kubelet 失聯，整個節點 NotReady | 1.6 資源保留 |
| 監控腳本每 10 秒 `kubectl get pods -A` | apiserver 與 etcd 被 list 請求壓垮 | 用 watch / informer；或用 metrics 而非 list |
| Flannel 用在需要 NetworkPolicy 的正式環境 | NetworkPolicy 建立成功但完全不生效，產生安全假象 | Calico / Cilium |
| 單一 StorageClass 給所有工作負載 | 日誌與資料庫搶同一組磁碟 IOPS | 依效能等級分 StorageClass |
| 沒有 PDB 就執行節點升級 | drain 一次驅逐所有副本，服務中斷 | 每個正式服務都有 PDB |

### 5.4 建議的實施路線圖

```
Phase 0 ── 安裝前（1–2 週）
  ├─ 需求收集與分析（需求分析章節）
  ├─ 確定不可逆決策：CIDR ×2、control-plane-endpoint、CNI、版本、叢集 DNS 網域
  ├─ 產出 kubeadm-config.yaml 並進 Git
  └─ 磁碟 fio 測試、網路 MTU 確認、防火牆申請

Phase 1 ── 叢集上線（第 1 週）
  ├─ 安裝 3 CP HA（2.2）+ Worker
  ├─ 資源保留 + evictionHard（1.6）
  ├─ metrics-server + kube-prometheus-stack（1.9）
  ├─ etcd 備份 timer + 異地（3.2）
  └─ GitOps（Argo CD / Flux）接管所有部署（3.5）

Phase 2 ── 強化（第 1 個月）
  ├─ 稽核日誌 + Secret 加密 + Pod Security（需求分析第七節）
  ├─ OIDC + RBAC 分權
  ├─ CoreDNS / Ingress 反親和 + PDB（2.7）
  ├─ Velero + DB 原生備份（3.3）
  ├─ 所有正式服務補齊 replicas / spread / PDB / probe（2.5）
  └─ 第一次 etcd 還原演練（測試叢集）

Phase 3 ── 持續營運（每季）
  ├─ 依指標調優（1.3–1.8），不預先猜測
  ├─ DR 演練：Control Plane 故障、Worker 故障、Velero 還原（4.4）
  ├─ 每 6 個月升級一個 minor 版本
  ├─ 檢視容量：節點 request 佔比、Pod CIDR 用量、etcd DB 大小
  └─ 更新 runbook 與需求文件的決策紀錄
```

每個 Phase 的完成標準對應本章的檢核表：Phase 1 → 2.10 HA 檢核表前半；Phase 2 → 4.5 DR 檢核表；Phase 3 → 兩張檢核表全部打勾且演練紀錄在一年內。

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
