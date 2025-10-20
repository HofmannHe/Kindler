#!/usr/bin/env bash
# 自动修复 HAProxy 路由：为所有业务集群添加路由

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

echo "=========================================="
echo "  自动添加业务集群 HAProxy 路由"
echo "=========================================="
echo ""

# 从 CSV 读取所有业务集群（排除 devops）
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1","$2}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "[WARN] No business clusters found in CSV"
  exit 0
fi

total=0
success=0
failed=0

while IFS=',' read -r cluster_name provider; do
  total=$((total + 1))
  echo "[$total] Adding route for $cluster_name ($provider)..."
  
  if "$ROOT_DIR/scripts/haproxy_route.sh" add "$cluster_name" --node-port 30080 2>&1 | grep -q "added\|already"; then
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

if [ $failed -gt 0 ]; then
  exit 1
fi
