#!/usr/bin/env bash
# Deployment 健康检查测试
# 验证所有集群的关键 Deployment 处于健康状态

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"
. "$ROOT_DIR/scripts/lib.sh"

echo "=========================================="
echo "Deployment Health Tests"
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
  
  # 检查 Traefik Deployment（业务集群必须有）
  if [ "$cluster" != "devops" ]; then
    echo "  [1/2] Traefik Deployment"
    
    if ! kubectl --context "$ctx" get deployment traefik -n traefik >/dev/null 2>&1; then
      echo "    ✗ Traefik deployment not found"
      failed_tests=$((failed_tests + 1))
    else
      # 检查 deployment conditions
      available=$(kubectl --context "$ctx" get deployment traefik -n traefik \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
      ready_replicas=$(kubectl --context "$ctx" get deployment traefik -n traefik \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      desired_replicas=$(kubectl --context "$ctx" get deployment traefik -n traefik \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
      
      if [ "$available" = "True" ] && [ "$ready_replicas" = "$desired_replicas" ]; then
        echo "    ✓ Traefik deployment healthy (Available=True, $ready_replicas/$desired_replicas ready)"
        passed_tests=$((passed_tests + 1))
      else
        echo "    ✗ Traefik deployment not healthy"
        echo "      Available: $available"
        echo "      Ready: $ready_replicas/$desired_replicas"
        failed_tests=$((failed_tests + 1))
      fi
    fi
    total_tests=$((total_tests + 1))
    
    # 检查 Traefik Pods
    echo "  [2/2] Traefik Pods"
    pods_ready=$(kubectl --context "$ctx" get pods -n traefik -l app=traefik \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    
    if echo "$pods_ready" | grep -q "True"; then
      echo "    ✓ Traefik pods ready"
      passed_tests=$((passed_tests + 1))
    else
      echo "    ✗ Traefik pods not ready"
      kubectl --context "$ctx" get pods -n traefik -l app=traefik || true
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  fi
  
  # devops 集群：检查关键管理服务
  if [ "$cluster" = "devops" ]; then
    echo "  [1/3] ArgoCD Server Deployment"
    if kubectl --context "$ctx" get deployment argocd-server -n argocd >/dev/null 2>&1; then
      ready=$(kubectl --context "$ctx" get deployment argocd-server -n argocd \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [ "$ready" -gt 0 ]; then
        echo "    ✓ ArgoCD server ready ($ready replicas)"
        passed_tests=$((passed_tests + 1))
      else
        echo "    ✗ ArgoCD server not ready"
        failed_tests=$((failed_tests + 1))
      fi
    else
      echo "    ✗ ArgoCD server deployment not found"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    echo "  [2/3] Portainer (Docker Compose)"
    # devops集群的Portainer通过Docker Compose部署，检查Docker容器
    if docker ps --filter "name=portainer-ce" --format "{{.Names}}" | grep -q "portainer-ce"; then
      portainer_status=$(docker inspect portainer-ce --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
      if [ "$portainer_status" = "running" ]; then
        echo "    ✓ Portainer container running"
        passed_tests=$((passed_tests + 1))
      else
        echo "    ✗ Portainer container not running (status: $portainer_status)"
        failed_tests=$((failed_tests + 1))
      fi
    else
      echo "    ✗ Portainer container not found"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    echo "  [3/3] PostgreSQL StatefulSet (optional)"
    if kubectl --context "$ctx" get statefulset postgresql -n paas >/dev/null 2>&1; then
      ready=$(kubectl --context "$ctx" get statefulset postgresql -n paas \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [ "$ready" -gt 0 ] 2>/dev/null; then
        echo "    ✓ PostgreSQL ready ($ready replicas)"
        passed_tests=$((passed_tests + 1))
        total_tests=$((total_tests + 1))
      else
        echo "    ⚠ PostgreSQL present but not ready (optional, skipped)"
        # optional component: do not count towards pass/fail totals
      fi
    else
      echo "    ⚠ PostgreSQL statefulset not found (optional, skipped)"
      # optional component: do not count towards pass/fail totals
    fi
  fi
done

print_summary







