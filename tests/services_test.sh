#!/usr/bin/env bash
# 服务访问测试
# 验证关键服务通过 HAProxy 正确访问

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
echo "Service Access Tests"
echo "=========================================="

# 1. ArgoCD 访问测试
echo ""
echo "[1/5] ArgoCD Service"
response=$(curl -s -m 10 -H "Host: argocd.devops.$BASE_DOMAIN" "http://$HAPROXY_HOST/" 2>&1 || echo "TIMEOUT")
assert_contains "$response" "Argo CD" "ArgoCD page loads via HAProxy"
assert_http_status "200" "http://$HAPROXY_HOST/" "argocd.devops.$BASE_DOMAIN" "ArgoCD returns 200 OK"

# 2. Portainer HTTP 跳转测试
echo ""
echo "[2/5] Portainer Service"
assert_http_status "301" "http://$HAPROXY_HOST/" "portainer.devops.$BASE_DOMAIN" "Portainer redirects HTTP to HTTPS (301)"

location=$(curl -s -I -m 10 -H "Host: portainer.devops.$BASE_DOMAIN" "http://$HAPROXY_HOST/" 2>/dev/null | grep -i "^location:" | tr -d '\r' || echo "")
assert_contains "$location" "https://" "Portainer redirect location is HTTPS"

# 3. Git 服务测试
echo ""
echo "[3/5] Git Service"
response=$(curl -s -m 10 -H "Host: git.devops.$BASE_DOMAIN" "http://$HAPROXY_HOST/" 2>&1 || echo "TIMEOUT")
# Git 服务可能返回 Gitea 或者 Gogs，或者其他响应
if echo "$response" | grep -qE "(Gitea|Gogs|git|repository)" || [ "$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Host: git.devops.$BASE_DOMAIN" "http://$HAPROXY_HOST/" 2>/dev/null)" = "200" ]; then
  echo "  ✓ Git service accessible"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ Git service not accessible"
  echo "    Response: $(echo "$response" | head -1)"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 4. HAProxy 统计页面测试
echo ""
echo "[4/5] HAProxy Stats"
# 使用 HTTP 状态码检测（更可靠）
status_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Host: haproxy.devops.$BASE_DOMAIN" "http://$HAPROXY_HOST/stat" 2>/dev/null || echo "000")
if [ "$status_code" = "200" ]; then
  echo "  ✓ HAProxy stats page accessible"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ HAProxy stats not accessible (HTTP $status_code)"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 5. whoami 服务测试（所有业务集群）
echo ""
echo "[5/5] Whoami Services"
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in environments.csv"
else
  for cluster in $clusters; do
    provider=$(provider_for "$cluster")
    # 提取环境名（去掉 -k3d/-kind 后缀）
    env_name="${cluster%-k3d}"
    env_name="${env_name%-kind}"
    
    domain="whoami.$provider.$env_name.$BASE_DOMAIN"
    response=$(curl -s -m 10 -H "Host: $domain" "http://$HAPROXY_HOST/" 2>&1 || echo "TIMEOUT")
    
    if echo "$response" | grep -q "Hostname:"; then
      echo "  ✓ whoami on $cluster ($domain) accessible"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ whoami on $cluster ($domain) not accessible"
      echo "    Response: $(echo "$response" | head -1)"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  done
fi

print_summary

