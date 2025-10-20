#!/usr/bin/env bash
# 清理 K8s 中不在 DB 的集群
# 谨慎操作，需二次确认

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
. "$ROOT_DIR/scripts/lib_db.sh"

echo "=========================================="
echo "  清理孤立 Kubernetes 集群"
echo "=========================================="
echo ""
echo "⚠️  WARNING: This will DELETE Kubernetes clusters!"
echo ""

# 加载配置
load_env

# 读取 DB 中的集群列表
echo "[1/3] 读取数据库记录..."
if db_is_available 2>/dev/null; then
  db_clusters=$(db_exec "SELECT name FROM clusters ORDER BY name;" | tail -n +3 | head -n -2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo "  ✓ DB: $(echo "$db_clusters" | grep -c '^' || echo "0") clusters"
else
  echo "  ⚠ DB not available, using CSV"
  db_clusters=$(awk -F, 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv")
fi
echo ""

# 列出所有 K8s 集群
echo "[2/3] 检查 Kubernetes 集群..."
k8s_clusters=""
for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -E '^(k3d-|kind-)' | sed 's/^k3d-//;s/^kind-//' | sort); do
  k8s_clusters="${k8s_clusters}${ctx}"$'\n'
done
k8s_clusters=$(echo "$k8s_clusters" | grep -v '^$' || echo "")

if [ -z "$k8s_clusters" ]; then
  echo "  No K8s clusters found"
  exit 0
fi

echo "  Found $(echo "$k8s_clusters" | grep -c '^' || echo "0") clusters"
echo ""

# 查找孤立集群
orphaned=""
for cluster in $k8s_clusters; do
  if ! echo "$db_clusters" | grep -q "^${cluster}$"; then
    orphaned="${orphaned}${cluster}"$'\n'
    echo "  ✗ Orphaned: $cluster (not in DB)"
  fi
done

orphaned=$(echo "$orphaned" | grep -v '^$' || echo "")
orphaned_count=$(echo "$orphaned" | grep -c '^' || echo "0")

if [ "$orphaned_count" -eq 0 ]; then
  echo "  ✓ No orphaned clusters found"
  exit 0
fi

echo ""
echo "[3/3] 删除孤立集群..."
echo "  Found $orphaned_count orphaned clusters"
echo ""
echo "  Clusters to delete:"
echo "$orphaned" | sed 's/^/    - /'
echo ""
echo "⚠️  This operation CANNOT be undone!"
echo ""

read -p "Delete these clusters? (type 'DELETE' to confirm) " -r
echo ""

if [ "$REPLY" != "DELETE" ]; then
  echo "  Aborted"
  exit 0
fi

# 删除集群
deleted=0
failed=0

for cluster in $orphaned; do
  echo "  Deleting $cluster..."
  
  # 确定 provider
  if kubectl config get-contexts "k3d-$cluster" >/dev/null 2>&1; then
    provider="k3d"
  elif kubectl config get-contexts "kind-$cluster" >/dev/null 2>&1; then
    provider="kind"
  else
    echo "    ✗ Unknown provider"
    failed=$((failed + 1))
    continue
  fi
  
  # 删除集群
  if [ "$provider" = "k3d" ]; then
    if k3d cluster delete "$cluster" 2>&1 | sed 's/^/      /'; then
      echo "    ✓ Deleted (k3d)"
      deleted=$((deleted + 1))
    else
      echo "    ✗ Failed"
      failed=$((failed + 1))
    fi
  else
    if kind delete cluster --name "$cluster" 2>&1 | sed 's/^/      /'; then
      echo "    ✓ Deleted (kind)"
      deleted=$((deleted + 1))
    else
      echo "    ✗ Failed"
      failed=$((failed + 1))
    fi
  fi
done

echo ""
echo "=========================================="
echo "  完成"
echo "=========================================="
echo "  Deleted: $deleted"
echo "  Failed: $failed"
echo ""

if [ "$failed" -eq 0 ]; then
  echo "✅ All orphaned clusters cleaned!"
  exit 0
else
  echo "⚠️ Some clusters failed to delete"
  exit 1
fi


