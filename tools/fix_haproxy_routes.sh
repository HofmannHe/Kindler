#!/usr/bin/env bash
# 自动修复 HAProxy 路由：为所有业务集群添加路由

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"

echo "=========================================="
echo "  自动添加业务集群 HAProxy 路由"
echo "=========================================="
echo ""

# 优先从 SQLite 读取业务集群（排除 devops），回退到 CSV
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"
if db_is_available 2>/dev/null; then
  clusters=$(sqlite_query "SELECT name||','||provider||','||COALESCE(node_port,30080) FROM clusters WHERE name!='devops' ORDER BY name;" 2>/dev/null || echo "")
else
  clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1","$2","$3}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")
fi

if [ -z "$clusters" ]; then
  echo "[WARN] No business clusters found in CSV"
  exit 0
fi

total=0
success=0
failed=0

while IFS=',' read -r cluster_name provider node_port; do
  total=$((total + 1))
  echo "[$total] Adding route for $cluster_name ($provider)..."
  
  # 检查集群是否实际存在
  cluster_exists=0
  case "$provider" in
    k3d)
      if k3d cluster list 2>/dev/null | grep -q "^$cluster_name "; then
        cluster_exists=1
      fi
      ;;
    kind)
      if kind get clusters 2>/dev/null | grep -q "^$cluster_name$"; then
        cluster_exists=1
      fi
      ;;
  esac
  
  if [ $cluster_exists -eq 0 ]; then
    echo "  ⊘ Cluster not exist, skip"
    continue
  fi
  
  if "$ROOT_DIR/scripts/haproxy_route.sh" add "$cluster_name" --node-port "${node_port:-30080}" 2>&1 | grep -q "added\|already"; then
    echo "  ✓ Route added/exists"
    success=$((success + 1))
  else
    echo "  ✗ Failed to add route"
    failed=$((failed + 1))
  fi
done <<< "$clusters"

echo ""
echo "=========================================="
echo "Summary:"
echo "  Total:   $total"
echo "  Success: $success"
echo "  Failed:  $failed"
echo "=========================================="

# 在 bootstrap 阶段，此脚本仅做最佳努力的修复，不应导致流程失败
exit 0

