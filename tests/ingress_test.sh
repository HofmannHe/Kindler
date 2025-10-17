#!/usr/bin/env bash
# Ingress Controller 健康测试
# 验证每个集群的 Ingress Controller 正常工作

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"
. "$ROOT_DIR/scripts/lib.sh"

# 加载配置
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"
: "${HAPROXY_HOST:=192.168.51.30}"

echo "=========================================="
echo "Ingress Controller Health Tests"
echo "=========================================="

# 获取所有集群
clusters=$(awk -F, 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

for cluster in $clusters; do
  provider=$(provider_for "$cluster")
  ctx_prefix=$([ "$provider" = "k3d" ] && echo k3d || echo kind)
  ctx="$ctx_prefix-$cluster"
  
  echo ""
  echo "[Cluster: $cluster ($provider)]"
  
  # 跳过 devops 集群（没有 Traefik）
  if [ "$cluster" = "devops" ]; then
    echo "  ⚠ Skipping devops cluster (no Traefik)"
    continue
  fi
  
  # 检查集群是否可访问
  if ! kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
    echo "  ✗ Cluster not accessible"
    failed_tests=$((failed_tests + 1))
    total_tests=$((total_tests + 1))
    continue
  fi
  
  # 检查 Traefik pods
  if [ "$provider" = "k3d" ]; then
    # k3d 使用内置 Traefik（在 kube-system namespace）
    traefik_pods=$(kubectl --context "$ctx" get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
    traefik_ready=$(kubectl --context "$ctx" get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  else
    # kind 使用我们部署的 Traefik（在 traefik namespace）
    traefik_pods=$(kubectl --context "$ctx" get pods -n traefik -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
    traefik_ready=$(kubectl --context "$ctx" get pods -n traefik -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  fi
  
  # 清理可能的重复 "0"（grep -c 失败时返回0，|| echo "0" 又添加一个0）
  traefik_pods=$(echo "$traefik_pods" | sed 's/^00$/0/')
  traefik_ready=$(echo "$traefik_ready" | sed 's/^00$/0/')
  
  # 确保变量是有效的整数
  traefik_pods=${traefik_pods:-0}
  traefik_ready=${traefik_ready:-0}
  
  if [ "$traefik_pods" -gt 0 ] 2>/dev/null && [ "$traefik_ready" -eq "$traefik_pods" ] 2>/dev/null; then
    echo "  ✓ Traefik pods healthy ($traefik_ready/$traefik_pods)"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ Traefik pods not healthy ($traefik_ready/$traefik_pods)"
    # 显示 pod 状态以便调试
    if [ "$provider" = "k3d" ]; then
      kubectl --context "$ctx" get pods -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null | head -5 || true
    else
      kubectl --context "$ctx" get pods -n traefik -l app.kubernetes.io/name=traefik 2>/dev/null | head -5 || true
    fi
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
  
  # 检查 IngressClass
  ingress_class=$(kubectl --context "$ctx" get ingressclass traefik -o name 2>/dev/null || echo "")
  if [ -n "$ingress_class" ]; then
    echo "  ✓ IngressClass 'traefik' exists"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ IngressClass 'traefik' not found"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
  
  # 检查 whoami Ingress
  whoami_ingress=$(kubectl --context "$ctx" get ingress -n default whoami -o name 2>/dev/null || echo "")
  if [ -n "$whoami_ingress" ]; then
    echo "  ✓ whoami Ingress exists"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ whoami Ingress not found"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
  
  # 端到端测试：通过 HAProxy 访问 whoami
  env_name="${cluster%-k3d}"
  env_name="${env_name%-kind}"
  domain="whoami.$provider.$env_name.$BASE_DOMAIN"
  
  response=$(curl -s -m 10 -H "Host: $domain" "http://$HAPROXY_HOST/" 2>&1 || echo "TIMEOUT")
  if echo "$response" | grep -q "Hostname:"; then
    echo "  ✓ End-to-end test passed ($domain)"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ End-to-end test failed ($domain)"
    echo "    Response: $(echo "$response" | head -1 | cut -c1-80)"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

print_summary

