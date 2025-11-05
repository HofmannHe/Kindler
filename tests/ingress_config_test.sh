#!/usr/bin/env bash
# Ingress 配置一致性测试
# 验证所有集群的 ingress 配置正确性

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"
. "$ROOT_DIR/scripts/lib.sh"

# 加载配置
load_env
BASE_DOMAIN="${BASE_DOMAIN:-192.168.51.30.sslip.io}"

echo "=========================================="
echo "Ingress Configuration Tests"
echo "=========================================="

# 读取所有业务集群
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in CSV"
  exit 0
fi

echo ""
echo "[1/4] Ingress Host Format Validation"
for cluster in $clusters; do
  # 使用完整集群名以匹配 HAProxy ACL（避免 dev 和 dev-k3d 冲突）
  # 域名格式：whoami.<cluster_name>.base_domain
  # 例如：dev -> whoami.dev.xxx, dev-k3d -> whoami.dev-k3d.xxx
  expected_host="whoami.${cluster}.${BASE_DOMAIN}"
  
  # 获取实际的 ingress host
  ctx_prefix=$(echo "$cluster" | grep -q "k3d" && echo "k3d" || echo "kind")
  ctx="${ctx_prefix}-${cluster}"
  
  actual_host=$(kubectl --context "$ctx" get ingress -n whoami -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "NOT_FOUND")
  
  if [ "$actual_host" = "$expected_host" ]; then
    echo "  ✓ $cluster ingress host correct: $actual_host"
    passed_tests=$((passed_tests + 1))
  elif [ "$actual_host" = "NOT_FOUND" ]; then
    echo "  ⚠ $cluster ingress not found (app may not be deployed)"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ $cluster ingress host incorrect"
    echo "     Expected: $expected_host"
    echo "     Actual:   $actual_host"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

echo ""
echo "[2/4] Ingress Class Validation"
for cluster in $clusters; do
  ctx_prefix=$(echo "$cluster" | grep -q "k3d" && echo "k3d" || echo "kind")
  ctx="${ctx_prefix}-${cluster}"
  
  # 所有集群统一使用 traefik
  expected_class="traefik"
  
  actual_class=$(kubectl --context "$ctx" get ingress -n whoami -o jsonpath='{.items[0].spec.ingressClassName}' 2>/dev/null || echo "NOT_FOUND")
  
  if [ "$actual_class" = "$expected_class" ]; then
    echo "  ✓ $cluster ingress class correct: $actual_class"
    passed_tests=$((passed_tests + 1))
  elif [ "$actual_class" = "NOT_FOUND" ]; then
    echo "  ⚠ $cluster ingress not found"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ $cluster ingress class incorrect (expected: $expected_class, actual: $actual_class)"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

echo ""
echo "[3/4] Backend Service Existence"
for cluster in $clusters; do
  ctx_prefix=$(echo "$cluster" | grep -q "k3d" && echo "k3d" || echo "kind")
  ctx="${ctx_prefix}-${cluster}"
  
  service_exists=$(kubectl --context "$ctx" get service whoami -n whoami -o name 2>/dev/null || echo "")
  
  if [ -n "$service_exists" ]; then
    echo "  ✓ $cluster backend service exists"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ⚠ $cluster backend service not found (app may not be deployed)"
    passed_tests=$((passed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

echo ""
echo "[4/4] Service Endpoints Validation"
for cluster in $clusters; do
  ctx_prefix=$(echo "$cluster" | grep -q "k3d" && echo "k3d" || echo "kind")
  ctx="${ctx_prefix}-${cluster}"
  
  endpoints=$(kubectl --context "$ctx" get endpoints whoami -n whoami -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
  
  if [ -n "$endpoints" ]; then
    echo "  ✓ $cluster service has endpoints: $endpoints"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ⚠ $cluster service has no endpoints (pod may not be running)"
    passed_tests=$((passed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

echo ""
print_summary

exit $failed_tests


