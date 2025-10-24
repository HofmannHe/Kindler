#!/usr/bin/env bash
# ArgoCD Applications Health状态验证
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"

echo "=========================================="
echo "ArgoCD Applications Health Test"
echo "=========================================="
echo ""

passed=0
failed=0

# 检查所有whoami Applications
for cluster in dev uat prod; do
  app="whoami-$cluster"
  echo "[$app] 检查Health状态..."
  
  health=$(kubectl --context k3d-devops -n argocd get application $app \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NOT_FOUND")
  sync=$(kubectl --context k3d-devops -n argocd get application $app \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NOT_FOUND")
  
  if [ "$health" = "Healthy" ] && [ "$sync" = "Synced" ]; then
    echo "  ✓ $app: Health=$health, Sync=$sync"
    passed=$((passed + 1))
  else
    echo "  ✗ $app: Health=$health, Sync=$sync"
    # 输出详细错误信息
    kubectl --context k3d-devops -n argocd get application $app \
      -o jsonpath='{.status.conditions[*].message}' 2>/dev/null | head -1 | \
      sed 's/^/    Error: /'
    failed=$((failed + 1))
  fi
done

echo ""
echo "=========================================="
echo "Total:  $((passed + failed))"
echo "Passed: $passed"
echo "Failed: $failed"
echo "=========================================="

[ $failed -eq 0 ] && exit 0 || exit 1
