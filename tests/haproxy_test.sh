#!/usr/bin/env bash
# HAProxy 配置测试
# 验证 HAProxy 配置文件正确性和路由规则

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"
. "$ROOT_DIR/scripts/lib.sh"

CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"

echo "=========================================="
echo "HAProxy Configuration Tests"
echo "=========================================="

# 1. HAProxy 配置语法测试
echo ""
echo "[1/5] Configuration Syntax"
if docker ps --filter name=haproxy-gw --format "{{.Names}}" | grep -q haproxy-gw; then
  validation_output=$(docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 2>&1)
  validation=$(echo "$validation_output" | grep -c "ALERT" || echo "0")
  assert_equals "0" "$validation" "HAProxy configuration syntax valid (no ALERT)"
  
  # 检查是否有警告（非致命，但应该注意）
  warnings=$(docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 2>&1 | grep -c "WARNING" || echo "0")
  if [ "$warnings" -gt 0 ]; then
    echo "  ⚠ HAProxy configuration has $warnings warning(s)"
  fi
else
  echo "  ✗ HAProxy container not running"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

# 2. 动态路由配置测试
echo ""
echo "[2/5] Dynamic Routes Configuration"
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in environments.csv"
else
  for cluster in $clusters; do
    # 检查 ACL 定义（http 和 https frontend 各一个）
    acl_count=$(grep -c "acl host_$cluster" "$CFG" 2>/dev/null || echo "0")
    
    if [ "$acl_count" -ge 1 ]; then
      echo "  ✓ ACL for $cluster exists ($acl_count occurrences)"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ ACL for $cluster not found"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    # 检查 backend 定义
    backend_count=$(grep -c "^backend be_$cluster" "$CFG" 2>/dev/null || echo "0")
    assert_equals "1" "$backend_count" "Backend for $cluster exists"
  done
fi

# 3. Backend 可达性测试
echo ""
echo "[3/5] Backend Reachability"
if docker ps --filter name=haproxy-gw --format "{{.Names}}" | grep -q haproxy-gw; then
  # 提取所有业务集群的 backend
  backends=$(awk '/^backend be_(dev|prod|uat)/ {backend=$2} /^[[:space:]]+server s1/ && backend {print backend":"$3; backend=""}' "$CFG" 2>/dev/null || echo "")
  
  if [ -n "$backends" ]; then
    for backend_addr in $backends; do
      backend_name=$(echo "$backend_addr" | cut -d: -f1)
      ip_port=$(echo "$backend_addr" | cut -d: -f2,3)
      ip=$(echo "$ip_port" | cut -d: -f1)
      
      # 从 HAProxy 容器测试 ping 连通性
      if docker exec haproxy-gw ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        echo "  ✓ $backend_name ($ip) reachable from HAProxy"
        passed_tests=$((passed_tests + 1))
      else
        echo "  ✗ $backend_name ($ip) unreachable from HAProxy"
        failed_tests=$((failed_tests + 1))
      fi
      total_tests=$((total_tests + 1))
    done
  else
    echo "  ⚠ No business cluster backends found in configuration"
  fi
else
  echo "  ✗ HAProxy container not running"
fi

# 4. 域名规则一致性测试
echo ""
echo "[4/5] Domain Pattern Consistency"
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found"
else
  for cluster in $clusters; do
    provider=$(provider_for "$cluster")
    # 提取环境名（去掉 -k3d/-kind 后缀）
    env_name="${cluster%-k3d}"
    env_name="${env_name%-kind}"
    
    expected_pattern="\\.$provider\\.$env_name\\."
    
    acl_line=$(grep "acl host_$cluster" "$CFG" | head -1 2>/dev/null || echo "")
    if [ -n "$acl_line" ]; then
      if echo "$acl_line" | grep -q "$expected_pattern"; then
        echo "  ✓ $cluster domain pattern correct ($provider.$env_name)"
        passed_tests=$((passed_tests + 1))
      else
        echo "  ✗ $cluster domain pattern incorrect"
        echo "    Expected: $expected_pattern"
        echo "    Actual: $acl_line"
        failed_tests=$((failed_tests + 1))
      fi
      total_tests=$((total_tests + 1))
    fi
  done
fi

# 5. 核心服务路由测试
echo ""
echo "[5/5] Core Service Routes"
for service in argocd portainer git haproxy_stats; do
  service_display="${service/_/ }"
  if grep -q "acl host_$service" "$CFG" 2>/dev/null; then
    echo "  ✓ $service_display route configured"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ $service_display route not found"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

print_summary

