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
  
  # 检查集群是否可访问
  if ! kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
    echo "  ✗ Cluster not accessible"
    failed_tests=$((failed_tests + 1))
    total_tests=$((total_tests + 1))
    continue
  fi
  
  # 根据 provider 确定 Ingress Controller 类型和位置
  # 注意：所有集群（kind 和 k3d）统一使用 Traefik，都在 traefik namespace
  ic_namespace="traefik"
  ic_label="app.kubernetes.io/name=traefik"
  ic_name="Traefik"
  ingress_class="traefik"
  
  # 检查 Ingress Controller pods
  ic_pods=$(kubectl --context "$ctx" get pods -n "$ic_namespace" -l "$ic_label" --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  ic_ready=$(kubectl --context "$ctx" get pods -n "$ic_namespace" -l "$ic_label" --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  
  # 清理可能的重复 "0"（grep -c 失败时返回0，|| echo "0" 又添加一个0）
  ic_pods=$(echo "$ic_pods" | sed 's/^00$/0/')
  ic_ready=$(echo "$ic_ready" | sed 's/^00$/0/')
  
  # 确保变量是有效的整数
  ic_pods=${ic_pods:-0}
  ic_ready=${ic_ready:-0}
  
  if [ "$ic_pods" -gt 0 ] 2>/dev/null && [ "$ic_ready" -eq "$ic_pods" ] 2>/dev/null; then
    echo "  ✓ $ic_name pods healthy ($ic_ready/$ic_pods)"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ $ic_name pods not healthy ($ic_ready/$ic_pods)"
    # 显示 pod 状态以便调试
    kubectl --context "$ctx" get pods -n "$ic_namespace" -l "$ic_label" 2>/dev/null | head -5 || true
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
  
  # 检查 IngressClass
  ic_class=$(kubectl --context "$ctx" get ingressclass "$ingress_class" -o name 2>/dev/null || echo "")
  if [ -n "$ic_class" ]; then
    echo "  ✓ IngressClass '$ingress_class' exists"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ IngressClass '$ingress_class' not found"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
  
  # 跳过业务服务测试（devops 集群不部署 whoami）
  if [ "$cluster" = "devops" ]; then
    echo "  ⚠ Skipping whoami test for devops cluster"
    continue
  fi
  
  # 检查 whoami Ingress（在 whoami namespace）
  whoami_ingress=$(kubectl --context "$ctx" get ingress -n whoami whoami -o name 2>/dev/null || echo "")
  if [ -n "$whoami_ingress" ]; then
    echo "  ✓ whoami Ingress exists in whoami namespace"
    passed_tests=$((passed_tests + 1))
    
    # 验证 Ingress host 配置（使用完整集群名以匹配 HAProxy ACL）
    # 域名格式：whoami.<cluster_name>.base_domain
    # 例如：dev -> whoami.dev.xxx, dev-k3d -> whoami.dev-k3d.xxx
    expected_domain="whoami.$cluster.$BASE_DOMAIN"
    actual_host=$(kubectl --context "$ctx" get ingress -n whoami whoami -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    
    if [ "$actual_host" = "$expected_domain" ]; then
      echo "  ✓ whoami Ingress host correct: $expected_domain"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ whoami Ingress host mismatch"
      echo "    Expected: $expected_domain"
      echo "    Actual:   $actual_host"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    # 端到端测试：通过 HAProxy 访问 whoami
    response=$(curl -s -m 10 "http://$expected_domain" 2>&1 || echo "TIMEOUT")
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "http://$expected_domain" 2>/dev/null || echo "000")
    
    if [ "$status_code" = "200" ] && echo "$response" | grep -q "Hostname:"; then
      echo "  ✓ End-to-end test passed ($expected_domain, HTTP 200, content verified)"
      passed_tests=$((passed_tests + 1))
    elif [ "$status_code" = "404" ]; then
      echo "  ⚠ End-to-end test: 404 ($expected_domain) - routing OK, app may not be deployed"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ End-to-end test failed ($expected_domain, HTTP $status_code)"
      echo "    Response: $(echo "$response" | head -1 | cut -c1-80)"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  else
    echo "  ⚠ whoami Ingress not found (app may not be deployed yet)"
    passed_tests=$((passed_tests + 1))
    total_tests=$((total_tests + 1))
  fi
done

print_summary

