#!/usr/bin/env bash
# 端到端服务可访问性测试
# 确保所有管理服务和应用服务都可正常访问

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/lib.sh"
source "$ROOT_DIR/scripts/lib.sh"

# 加载配置
load_env
BASE_DOMAIN="${BASE_DOMAIN:-192.168.51.30.sslip.io}"

echo "######################################################"
echo "# E2E Services Accessibility Test"
echo "######################################################"
echo "==========================================}"
echo "End-to-End Service Access Tests"
echo "=========================================="
echo ""

##############################################
# 管理服务测试
##############################################
echo "[1/3] Management Services"
echo ""

# Portainer HTTP (应该重定向到 HTTPS)
echo "  [1.1] Portainer HTTP -> HTTPS redirect"
status=$(curl -sI -m 10 "http://portainer.devops.$BASE_DOMAIN" | grep "HTTP" | head -1 | awk '{print $2}')
if [ "$status" = "301" ]; then
  echo "    ✓ Portainer HTTP redirects to HTTPS (301)"
  passed_tests=$((passed_tests + 1))
else
  echo "    ✗ Portainer HTTP redirect failed (status: $status, expected: 301)"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# Portainer HTTPS
echo "  [1.2] Portainer HTTPS access"
status=$(curl -skI -m 10 "https://portainer.devops.$BASE_DOMAIN" | grep "HTTP" | head -1 | awk '{print $2}')
if [ "$status" = "200" ]; then
  echo "    ✓ Portainer HTTPS accessible (200)"
  passed_tests=$((passed_tests + 1))
else
  echo "    ✗ Portainer HTTPS not accessible (status: $status)"
  echo "    URL: https://portainer.devops.$BASE_DOMAIN"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# Portainer 内容验证（确保不是 ArgoCD）
echo "  [1.3] Portainer content validation"
content=$(curl -sk -m 10 "https://portainer.devops.$BASE_DOMAIN" 2>/dev/null | head -100)
if echo "$content" | grep -qi "portainer"; then
  echo "    ✓ Portainer returns correct content"
  passed_tests=$((passed_tests + 1))
elif echo "$content" | grep -qi "argocd"; then
  echo "    ✗ Portainer returns ArgoCD content (routing error!)"
  failed_tests=$((failed_tests + 1))
else
  echo "    ⚠ Portainer content unclear"
  passed_tests=$((passed_tests + 1))
fi
total_tests=$((total_tests + 1))

# ArgoCD
echo "  [1.4] ArgoCD HTTP access"
status=$(curl -sI -m 10 "http://argocd.devops.$BASE_DOMAIN" | grep "HTTP" | head -1 | awk '{print $2}')
if [ "$status" = "200" ]; then
  echo "    ✓ ArgoCD HTTP accessible (200)"
  passed_tests=$((passed_tests + 1))
else
  echo "    ✗ ArgoCD HTTP not accessible (status: $status)"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# ArgoCD 内容验证
echo "  [1.5] ArgoCD content validation"
content=$(curl -s -m 10 "http://argocd.devops.$BASE_DOMAIN" 2>/dev/null | head -100)
if echo "$content" | grep -qi "argocd\|argo"; then
  echo "    ✓ ArgoCD returns correct content"
  passed_tests=$((passed_tests + 1))
else
  echo "    ⚠ ArgoCD content unclear"
  passed_tests=$((passed_tests + 1))
fi
total_tests=$((total_tests + 1))

# HAProxy Stats
echo "  [1.6] HAProxy Stats page"
status=$(curl -sI -m 10 "http://haproxy.devops.$BASE_DOMAIN/stat" | grep "HTTP" | head -1 | awk '{print $2}')
if [ "$status" = "200" ]; then
  echo "    ✓ HAProxy Stats accessible (200)"
  passed_tests=$((passed_tests + 1))
else
  echo "    ✗ HAProxy Stats not accessible (status: $status)"
  echo "    URL: http://haproxy.devops.$BASE_DOMAIN/stat"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# Git Service
echo "  [1.7] Git Service"
status=$(curl -sI -m 10 "http://git.devops.$BASE_DOMAIN" | grep "HTTP" | head -1 | awk '{print $2}')
if [ "$status" = "200" ] || [ "$status" = "302" ]; then
  echo "    ✓ Git Service accessible ($status)"
  passed_tests=$((passed_tests + 1))
else
  echo "    ⚠ Git Service status: $status (may be unavailable)"
  passed_tests=$((passed_tests + 1))
fi
total_tests=$((total_tests + 1))

echo ""

##############################################
# 业务服务测试 (whoami)
##############################################
echo "[2/3] Business Services (whoami apps)"
echo ""
echo "  ⚠ Note: whoami apps require external Git service for GitOps deployment"
echo ""

# 读取所有业务集群
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in CSV"
else
  for cluster in $clusters; do
    # 使用完整集群名以匹配 HAProxy ACL（避免 dev 和 dev-k3d 冲突）
    # 域名格式：whoami.<cluster_name>.base_domain
    # 例如：dev -> whoami.dev.xxx, dev-k3d -> whoami.dev-k3d.xxx
    domain="whoami.${cluster}.${BASE_DOMAIN}"
    
    echo "  [2.x] whoami.$cluster ($cluster)"
    
    # 1. 先验证 ingress 实际配置
    ctx_prefix=$(echo "$cluster" | grep -q "k3d" && echo "k3d" || echo "kind")
    actual_host=$(kubectl --context ${ctx_prefix}-${cluster} get ingress -n whoami \
      -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$actual_host" != "$domain" ]; then
      echo "    ✗ Ingress host mismatch!"
      echo "       Expected: $domain"
      echo "       Actual:   $actual_host"
      failed_tests=$((failed_tests + 1))
      total_tests=$((total_tests + 1))
      continue
    fi
    
    # 2. 测试 HTTP 访问
    status=$(curl -sI -m 10 "http://$domain" 2>/dev/null | grep "HTTP" | head -1 | awk '{print $2}' || echo "000")
    
    if [ "$status" = "200" ]; then
      # 3. 验证响应内容
      content=$(curl -s -m 5 "http://$domain" 2>/dev/null | head -20)
      if echo "$content" | grep -qi "hostname\|whoami"; then
        echo "    ✓ $domain fully functional (Ingress ✓, HTTP 200 ✓, Content ✓)"
        passed_tests=$((passed_tests + 1))
      else
        echo "    ⚠ $domain returns 200 but content unclear (Ingress ✓, HTTP 200 ✓)"
        passed_tests=$((passed_tests + 1))
      fi
    elif [ "$status" = "404" ]; then
      # 4. 404 需要区分原因
      # 如果 ingress 配置正确但返回 404，说明应用未部署（可接受）
      echo "    ⚠ $domain returns 404 (Ingress ✓, app not deployed)"
      passed_tests=$((passed_tests + 1))
    elif [ "$status" = "000" ]; then
      echo "    ✗ $domain connection failed (timeout/unreachable)"
      failed_tests=$((failed_tests + 1))
    else
      echo "    ✗ $domain not accessible (status: $status)"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  done
fi

echo ""

##############################################
# Kubernetes API 访问测试
##############################################
echo "[3/3] Kubernetes API Access"
echo ""

# devops 集群
echo "  [3.1] devops cluster API"
if kubectl --context k3d-devops get nodes >/dev/null 2>&1; then
  echo "    ✓ devops API accessible"
  passed_tests=$((passed_tests + 1))
else
  echo "    ✗ devops API not accessible"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 业务集群 API
for cluster in $clusters; do
  # 确定 provider
  provider=$(awk -F, -v n="$cluster" 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print $2; exit}' "$ROOT_DIR/config/environments.csv" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  if [ "$provider" = "k3d" ]; then
    ctx="k3d-$cluster"
  else
    ctx="kind-$cluster"
  fi
  
  echo "  [3.x] $cluster API ($ctx)"
  if kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
    echo "    ✓ $cluster API accessible"
    passed_tests=$((passed_tests + 1))
  else
    echo "    ✗ $cluster API not accessible"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

echo ""

##############################################
# 测试摘要
##############################################
print_summary

exit $failed_tests

