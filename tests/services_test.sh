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

# 等待 ArgoCD ApplicationSet 同步完成（最多 180 秒）
echo "  Waiting for ArgoCD to sync whoami applications..."
max_wait=180
waited=0
while [ $waited -lt $max_wait ]; do
  # 检查 whoami-* applications 的状态
  synced_count=$(kubectl --context k3d-devops get applications -n argocd -l app=whoami -o jsonpath='{range .items[*]}{.status.sync.status}{"\n"}{end}' 2>/dev/null | grep -c "Synced" || echo 0)
  total_count=$(kubectl --context k3d-devops get applications -n argocd -l app=whoami --no-headers 2>/dev/null | wc -l || echo 0)
  
  if [ "$total_count" -gt 0 ] && [ "$synced_count" -eq "$total_count" ]; then
    echo "  ✓ All $total_count whoami applications synced (waited ${waited}s)"
    break
  fi
  
  if [ $((waited % 30)) -eq 0 ]; then
    echo "  ⏳ Waiting for ArgoCD sync... ($synced_count/$total_count synced, ${waited}s elapsed)"
  fi
  
  sleep 5
  waited=$((waited + 5))
done

if [ $waited -ge $max_wait ]; then
  echo "  ⚠ ArgoCD sync timeout after ${max_wait}s - some applications may not be ready"
fi

# 获取业务集群列表
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

# Helper函数：从CSV获取集群的provider
get_provider() {
  local cluster_name="$1"
  awk -F, -v name="$cluster_name" 'NR>1 && $1==name && $0 !~ /^[[:space:]]*#/ {print $2; exit}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "k3d"
}

# 等待所有 whoami pods 就绪（最多 120 秒）
echo "  Waiting for all whoami pods to be ready..."
max_pod_wait=120
pod_waited=0
while [ $pod_waited -lt $max_pod_wait ]; do
  ready_count=0
  for cluster in $clusters; do
    provider=$(get_provider "$cluster")
    ctx="${provider}-${cluster}"
    pod_ready=$(kubectl --context "$ctx" get pods -n whoami -l app=whoami -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "$pod_ready" = "True" ] && ready_count=$((ready_count + 1))
  done
  
  total_clusters=$(echo "$clusters" | wc -w)
  if [ "$ready_count" -eq "$total_clusters" ]; then
    echo "  ✓ All $total_clusters whoami pods are ready (waited ${pod_waited}s)"
    break
  fi
  
  if [ $((pod_waited % 30)) -eq 0 ]; then
    echo "  ⏳ Waiting for pods... ($ready_count/$total_clusters ready, ${pod_waited}s elapsed)"
  fi
  
  sleep 5
  pod_waited=$((pod_waited + 5))
done

if [ $pod_waited -ge $max_pod_wait ]; then
  echo "  ⚠ Pod readiness timeout after ${max_pod_wait}s - some tests may fail"
fi

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in environments.csv"
else
  for cluster in $clusters; do
    # 使用完整集群名以匹配 HAProxy ACL（避免 dev 和 dev-k3d 冲突）
    # 域名格式：whoami.<cluster_name>.base_domain
    # 例如：dev -> whoami.dev.xxx, dev-k3d -> whoami.dev-k3d.xxx
    domain="whoami.$cluster.$BASE_DOMAIN"
    
    # 1. 先检查 ingress 配置
    provider=$(get_provider "$cluster")
    ctx="${provider}-${cluster}"
    actual_host=$(kubectl --context "$ctx" get ingress -n whoami -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$actual_host" != "$domain" ] && [ "$actual_host" != "NOT_FOUND" ]; then
      echo "  ✗ whoami on $cluster ingress host mismatch (expected: $domain, actual: $actual_host)"
      failed_tests=$((failed_tests + 1))
      total_tests=$((total_tests + 1))
      continue
    fi
    
    # 2. 测试 HTTP 访问
    response=$(curl -s -m 10 -H "Host: $domain" "http://$HAPROXY_HOST/" 2>&1 || echo "TIMEOUT")
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "http://$domain" 2>/dev/null || echo "000")
    
    if [ "$status_code" = "200" ] && echo "$response" | grep -q "Hostname:"; then
      echo "  ✓ whoami on $cluster ($domain) fully functional"
      passed_tests=$((passed_tests + 1))
    else
      # 任何非200状态都是失败
      if [ "$actual_host" = "NOT_FOUND" ]; then
        echo "  ✗ whoami on $cluster not deployed (ingress not found)"
      elif [ "$status_code" = "404" ]; then
        echo "  ✗ whoami on $cluster returns 404 (routing config OK, app not deployed)"
      elif [ "$status_code" = "502" ] || [ "$status_code" = "503" ]; then
        echo "  ✗ whoami on $cluster returns $status_code (backend not ready)"
      else
        echo "  ✗ whoami on $cluster ($domain) not accessible (status: $status_code)"
        echo "    Response: $(echo "$response" | head -1)"
      fi
      failed_tests=$((failed_tests + 1))
    fi
  done
fi

print_summary

