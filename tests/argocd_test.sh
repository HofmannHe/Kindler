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
  registered_clusters=$(kubectl --context k3d-devops get secrets -n argocd -l "argocd.argoproj.io/secret-type=cluster" --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  registered_clusters=$(echo "$registered_clusters" | sed 's/^00$/0/')
  registered_clusters=${registered_clusters:-0}
  expected_clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {count++} END {print count}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "0")
  expected_clusters=$(echo "$expected_clusters" | sed 's/^00$/0/')
  expected_clusters=${expected_clusters:-0}
  
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
  git_repos=$(kubectl --context k3d-devops get secrets -n argocd -l "argocd.argoproj.io/secret-type=repository" --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  git_repos=$(echo "$git_repos" | sed 's/^00$/0/')
  git_repos=${git_repos:-0}
  
  if [ "$git_repos" -gt 0 ] 2>/dev/null; then
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

# 4. Application 同步状态（严格检查）
echo ""
echo "[4/5] Application Sync Status (Strict)"
if kubectl --context k3d-devops get namespace argocd >/dev/null 2>&1; then
  apps=$(kubectl --context k3d-devops get applications -n argocd --no-headers 2>/dev/null | grep whoami || echo "")
  
  if [ -n "$apps" ]; then
    total_apps=$(echo "$apps" | wc -l 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
    total_apps=$(echo "$total_apps" | sed 's/^00$/0/')
    total_apps=${total_apps:-0}
    synced_count=$(echo "$apps" | grep -c "Synced" 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
    synced_count=$(echo "$synced_count" | sed 's/^00$/0/')
    synced_count=${synced_count:-0}
    
    echo "  Applications found: $total_apps"
    echo "  - Synced: $synced_count/$total_apps"
    
    # 严格检查：所有应用必须 Synced（fail-fast）
    if [ "$total_apps" -gt 0 ] 2>/dev/null; then
      if [ "$synced_count" -eq "$total_apps" ] 2>/dev/null; then
        echo "  ✓ All applications synced"
        passed_tests=$((passed_tests + 1))
      else
        echo "  ✗ Not all applications synced ($synced_count/$total_apps)"
        # 显示未同步的应用
        echo "  OutOfSync applications:"
        kubectl --context k3d-devops get applications -n argocd --no-headers 2>/dev/null | \
          grep whoami | grep -v "Synced" | sed 's/^/    /' || true
        failed_tests=$((failed_tests + 1))
      fi
      total_tests=$((total_tests + 1))
    fi
  else
    echo "  ⚠ No whoami applications found"
  fi
else
  echo "  ✗ ArgoCD namespace not found"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

# 5. Application Warnings 检查（新增）
echo ""
echo "[5/5] Application Warnings Check"
if kubectl --context k3d-devops get namespace argocd >/dev/null 2>&1; then
  # 检查 RepeatedResourceWarning
  warning_count=$(kubectl --context k3d-devops get applications -n argocd -o yaml 2>/dev/null | \
    grep -c "RepeatedResourceWarning" 2>/dev/null || echo "0")
  # 清理并确保是单个数字
  warning_count=$(echo "$warning_count" | tr -d '\n\r' | grep -o '[0-9]*' | head -1 || echo "0")
  warning_count=${warning_count:-0}
  
  if [ "$warning_count" -eq 0 ]; then
    echo "  ✓ No RepeatedResourceWarning found"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ Found $warning_count RepeatedResourceWarning(s)"
    # 显示具体的警告
    kubectl --context k3d-devops get applications -n argocd -o json 2>/dev/null | \
      jq -r '.items[] | select(.status.conditions != null) | select(.status.conditions[] | .type == "RepeatedResourceWarning") | "    " + .metadata.name + ": " + (.status.conditions[] | select(.type == "RepeatedResourceWarning") | .message)' 2>/dev/null || true
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
else
  echo "  ✗ ArgoCD namespace not found"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

print_summary

