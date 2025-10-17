#!/usr/bin/env bash
# ArgoCD 集成测试
# 验证 ArgoCD 与集群的集成状态

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"

echo "=========================================="
echo "ArgoCD Integration Tests"
echo "=========================================="

# 1. ArgoCD Server 运行状态
echo ""
echo "[1/4] ArgoCD Server Status"
if kubectl --context k3d-devops get namespace argocd >/dev/null 2>&1; then
  argocd_ready=$(kubectl --context k3d-devops get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  assert_equals "1" "$argocd_ready" "ArgoCD server deployment ready"
  
  argocd_pods=$(kubectl --context k3d-devops get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
  assert_contains "$argocd_pods" "Running" "ArgoCD server pod running"
else
  echo "  ✗ ArgoCD namespace not found"
  failed_tests=$((failed_tests + 2))
  total_tests=$((total_tests + 2))
fi

# 2. 集群注册状态
echo ""
echo "[2/4] Cluster Registration"
if kubectl --context k3d-devops get namespace argocd >/dev/null 2>&1; then
  registered_clusters=$(kubectl --context k3d-devops get secrets -n argocd -l "argocd.argoproj.io/secret-type=cluster" --no-headers 2>/dev/null | wc -l)
  expected_clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {count++} END {print count}' "$ROOT_DIR/config/environments.csv")
  
  assert_equals "$expected_clusters" "$registered_clusters" "All business clusters registered in ArgoCD ($registered_clusters/$expected_clusters)"
else
  echo "  ✗ ArgoCD namespace not found"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

# 3. Git Repository 连接
echo ""
echo "[3/4] Git Repository Connection"
if kubectl --context k3d-devops get namespace argocd >/dev/null 2>&1; then
  git_repos=$(kubectl --context k3d-devops get secrets -n argocd -l "argocd.argoproj.io/secret-type=repository" --no-headers 2>/dev/null | wc -l)
  
  if [ "$git_repos" -gt 0 ]; then
    echo "  ✓ Git repositories configured ($git_repos)"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ⚠ No Git repositories configured"
  fi
  total_tests=$((total_tests + 1))
else
  echo "  ✗ ArgoCD namespace not found"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

# 4. Application 同步状态
echo ""
echo "[4/4] Application Sync Status"
if kubectl --context k3d-devops get namespace argocd >/dev/null 2>&1; then
  apps=$(kubectl --context k3d-devops get applications -n argocd --no-headers 2>/dev/null | grep whoami || echo "")
  
  if [ -n "$apps" ]; then
    total_apps=$(echo "$apps" | wc -l | tr -d ' \n')
    synced_count=$(echo "$apps" | grep -c "Synced" || echo "0")
    healthy_count=$(echo "$apps" | grep -c "Healthy" || echo "0")
    
    echo "  Applications found: $total_apps"
    echo "  - Synced: $synced_count/$total_apps"
    echo "  - Healthy: $healthy_count/$total_apps"
    
    # 至少一半的应用应该是 Synced 状态
    synced_threshold=$((total_apps / 2))
    if [ "$synced_count" -ge "$synced_threshold" ]; then
      echo "  ✓ Majority of applications synced"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ Too few applications synced ($synced_count/$total_apps)"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  else
    echo "  ⚠ No whoami applications found"
  fi
else
  echo "  ✗ ArgoCD namespace not found"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

print_summary

