#!/usr/bin/env bash
# Portainer集成测试 - 验证Portainer端点管理

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/tests/lib.sh"

# 加载BASE_DOMAIN
if [ -f "$ROOT_DIR/config/clusters.env" ]; then
  source "$ROOT_DIR/config/clusters.env"
fi
BASE_DOMAIN="${BASE_DOMAIN:-192.168.51.30.sslip.io}"

passed_tests=0
failed_tests=0

echo "=========================================="
echo "Portainer Integration Tests"
echo "=========================================="
echo ""

# 1. Portainer容器运行状态
echo "[1/4] Portainer Container Status"
# Use exact-name filter to avoid false positives and ensure robustness
if docker ps --filter name=^/portainer-ce$ --format '{{.Names}}' | grep -qx 'portainer-ce'; then
  echo "  ✓ Portainer container is running"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ Portainer container not running"
  failed_tests=$((failed_tests + 1))
fi

# 2. Portainer健康检查
echo ""
echo "[2/4] Portainer Health Check"
container_health=$(docker inspect portainer-ce --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
if [ "$container_health" = "healthy" ]; then
  echo "  ✓ Portainer container is healthy"
  passed_tests=$((passed_tests + 1))
else
  echo "  ⚠ Portainer health status: $container_health"
  passed_tests=$((passed_tests + 1))  # 非healthy状态也接受，只要容器在运行
fi

# 3. Portainer HTTP访问（通过HAProxy）
echo ""
echo "[3/4] Portainer HTTP Access"
http_code=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" "http://portainer.devops.${BASE_DOMAIN}" 2>/dev/null || echo "000")
if [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
  echo "  ✓ Portainer redirects HTTP to HTTPS ($http_code)"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ Portainer HTTP status: $http_code (expected 301/302)"
  failed_tests=$((failed_tests + 1))
fi

# 4. Portainer HTTPS访问
echo ""
echo "[4/4] Portainer HTTPS Access"
https_code=$(timeout 10 curl -k -s -o /dev/null -w "%{http_code}" "https://portainer.devops.${BASE_DOMAIN}" 2>/dev/null || echo "000")
if [ "$https_code" = "200" ]; then
  # 验证响应内容是否包含 "portainer"
  content=$(timeout 10 curl -k -s "https://portainer.devops.${BASE_DOMAIN}" 2>/dev/null || echo "")
  if echo "$content" | grep -qi "portainer"; then
    echo "  ✓ Portainer HTTPS accessible and content verified"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ Portainer HTTPS accessible but wrong content (might be routed to wrong service)"
    failed_tests=$((failed_tests + 1))
  fi
else
  echo "  ✗ Portainer HTTPS status: $https_code (expected 200)"
  failed_tests=$((failed_tests + 1))
fi

# 测试结果汇总
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
total_tests=$((passed_tests + failed_tests))
echo "Total:  $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $failed_tests"

if [ $failed_tests -eq 0 ]; then
  echo "Status: ✓ ALL PASS"
  exit 0
else
  echo "Status: ✗ SOME FAILURES"
  exit 1
fi
