#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# 加载配置
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"

echo "=== 快速验证脚本 ==="
echo "BASE_DOMAIN: $BASE_DOMAIN"
echo ""

# 定义要测试的服务
tests=(
  "argocd.devops.$BASE_DOMAIN|ArgoCD|Argo CD"
  "portainer.devops.$BASE_DOMAIN|Portainer HTTP|301 Moved"
  "whoami.k3d.dev.$BASE_DOMAIN|whoami (dev-k3d)|Hostname:"
  "whoami.k3d.prod.$BASE_DOMAIN|whoami (prod-k3d)|Hostname:"
  "whoami.k3d.uat.$BASE_DOMAIN|whoami (uat-k3d)|Hostname:"
)

total=0
passed=0
failed=0

for test in "${tests[@]}"; do
  IFS='|' read -r domain name expected <<< "$test"
  total=$((total + 1))
  
  echo -n "[$total] Testing $name ($domain)... "
  
  if response=$(curl -s -m 5 -H "Host: $domain" http://192.168.51.30/ 2>&1); then
    if echo "$response" | grep -q "$expected"; then
      echo "✓ PASS"
      passed=$((passed + 1))
    else
      echo "✗ FAIL (unexpected response)"
      echo "    Expected: $expected"
      echo "    Got: $(echo "$response" | head -1)"
      failed=$((failed + 1))
    fi
  else
    echo "✗ FAIL (timeout or error)"
    failed=$((failed + 1))
  fi
done

echo ""
echo "=== 验证结果 ==="
echo "Total:  $total"
echo "Passed: $passed"
echo "Failed: $failed"

if [ $failed -eq 0 ]; then
  echo "Status: ✓ ALL PASS"
  exit 0
else
  echo "Status: ✗ SOME FAILED"
  exit 1
fi

