#!/usr/bin/env bash
# whoami Pod运行状态验证
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"

echo "=========================================="
echo "Whoami Pod Status Test"
echo "=========================================="
echo ""

passed=0
failed=0

for cluster in dev uat prod; do
  echo "[$cluster] 检查whoami Pod状态..."
  
  ctx="k3d-$cluster"
  pod_status=$(kubectl --context $ctx -n whoami get pods -l app=whoami \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NOT_FOUND")
  ready=$(kubectl --context $ctx -n whoami get pods -l app=whoami \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  
  if [ "$pod_status" = "Running" ] && [ "$ready" = "true" ]; then
    pod_name=$(kubectl --context $ctx -n whoami get pods -l app=whoami \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    echo "  ✓ $cluster: Pod=$pod_name, Status=$pod_status, Ready=$ready"
    passed=$((passed + 1))
  else
    echo "  ✗ $cluster: Status=$pod_status, Ready=$ready"
    # 输出Pod详情
    kubectl --context $ctx -n whoami get pods -l app=whoami 2>/dev/null | tail -1 | \
      sed 's/^/    /' || echo "    Pod not found"
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
