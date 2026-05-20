#!/bin/bash
# Worker 節點加入叢集腳本
set -euo pipefail

echo ">>> [worker] 等待 Master 完成初始化..."

# 等待 master 產生 join-command.sh（最多 10 分鐘）
TIMEOUT=600
ELAPSED=0
while [ ! -f /vagrant/join-command.sh ]; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "錯誤：等待逾時，/vagrant/join-command.sh 不存在"
    exit 1
  fi
  echo "  尚未收到 join-command.sh，等待中... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo ">>> [worker] 收到 join 指令，加入叢集"
bash /vagrant/join-command.sh

echo ">>> [worker] 節點已成功加入叢集"
