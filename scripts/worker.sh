#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  worker.sh — Worker 節點加入叢集
# ═══════════════════════════════════════════════════════════════════════════
#
#  需求（Requirements）
#  ─────────────────────────────────────────────────────────────────────────
#  R1  在 master 尚未就緒時能自行等待，不需要人工介入排序
#  R2  等待要有上限，不能無限期卡住 vagrant up
#  R3  可重複執行：對已加入的節點重跑不得破壞它
#  R4  失敗時的訊息要能直接指出下一步該做什麼
#
#  設計決策（Design Decisions）
#  ─────────────────────────────────────────────────────────────────────────
#  D1  【輪詢 synced folder，而不是讓 host 排程】Vagrant 沒有「等另一台 VM 的
#      某個步驟完成」的原生機制。用共享檔案當號誌，好處是 `vagrant up
#      k8s-worker2` 這種單機啟動也能運作（檔案還在就直接用）。
#
#  D2  【逾時 10 分鐘】master 從開機到產生 join 指令，含拉映像大約 5-8 分鐘。
#      10 分鐘留了餘裕，又不至於在 master 真的失敗時讓使用者等到天荒地老。
#
#  D3  【執行前先驗證檔案內容】只檢查「檔案存在」是不夠的：master 可能正寫到
#      一半，或留著上一輪的空檔。確認內容含 "kubeadm join" 才動手。
#      （master 端也已改為「先寫暫存檔再 mv」，兩邊各守一半。）
#
#  D4  【冪等靠 kubelet.conf 判斷】節點成功 join 後會有 /etc/kubernetes/kubelet.conf。
#      在已加入的節點上重跑 kubeadm join 會直接失敗（port 10250 已占用、
#      設定檔已存在），vagrant provision 就會整個中斷。
#
#  D5  【不自己下 node-role label】worker 的角色標籤要有 apiserver 權限才能打，
#      而 worker 手上只有 bootstrap 憑證。這一步留給 master 或使用者從
#      master 執行（做法見 README「為 Worker 節點標記角色」）。
#
#  原則（Principles）
#  ─────────────────────────────────────────────────────────────────────────
#  P1  等待要能被觀察：每一輪都印出已等待秒數，讓人知道是在等、不是掛了。
#  P2  錯誤訊息附上可直接複製執行的修復指令。
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

JOIN_FILE="/vagrant/join-command.sh"
TIMEOUT=600
INTERVAL=10

# ── 0. 冪等檢查（見 D4）──────────────────────────────────────────────────────
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo ">>> [worker] 偵測到 /etc/kubernetes/kubelet.conf，本節點已加入叢集，略過 join"
  echo "    （要重新加入請先在本節點執行 kubeadm reset -f）"
  exit 0
fi

echo ">>> [worker] 等待 Master 完成初始化..."

# ── 1. 等待 master 產生 join 指令（見 D1 / D2 / D3）──────────────────────────
ELAPSED=0
while true; do
  # 存在 + 內容確實是 join 指令，才視為就緒
  if [ -s "${JOIN_FILE}" ] && grep -q "kubeadm join" "${JOIN_FILE}"; then
    break
  fi

  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "錯誤：等待逾時（${TIMEOUT}s），${JOIN_FILE} 不存在或內容不完整" >&2
    echo "  請確認 master 是否成功初始化：" >&2
    echo "    vagrant ssh k8s-master -c 'sudo kubectl get nodes'" >&2
    echo "  若 master 正常，重新產生 join 指令後再重試本節點：" >&2
    echo "    vagrant provision k8s-master" >&2
    echo "    vagrant provision $(hostname)" >&2
    exit 1
  fi

  echo "  尚未收到 join-command.sh，等待中... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# ── 2. 加入叢集 ───────────────────────────────────────────────────────────────
# 用 bash 執行而非依賴執行位元：/vagrant 是 vboxsf 掛載，權限由 mount 選項
# 決定，chmod +x 在部分 host 上不會生效（master.sh 因此也不做 chmod）。
echo ">>> [worker] 收到 join 指令，加入叢集"
if ! bash "${JOIN_FILE}"; then
  echo "" >&2
  echo "錯誤：kubeadm join 失敗" >&2
  echo "  最常見的原因是 token 已過期（kubeadm token 預設效期 24 小時），" >&2
  echo "  典型訊息為 \"token id ... is invalid\" 或 \"Unauthorized\"。" >&2
  echo "  在 host 上依序執行即可換發並重試：" >&2
  echo "    vagrant provision k8s-master" >&2
  echo "    vagrant provision $(hostname)" >&2
  exit 1
fi

echo ">>> [worker] 節點已成功加入叢集"
echo "    可在 master 上執行 kubectl get nodes 確認（節點轉為 Ready 需 CNI 就緒，約 30-60 秒）"
