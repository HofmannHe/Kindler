#!/usr/bin/env bash
# 测试运行器
# 统一入口运行所有或指定的测试模块

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$ROOT_DIR/tests"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# 验证初始状态：预置集群就绪
verify_initial_state() {
  echo "  Checking preset clusters..."
  
  # 从 environments.csv 读取预期的集群列表
  local expected_clusters=$(awk -F',' 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1 ":" $2}' "$ROOT_DIR/config/environments.csv")
  
  local total=0
  local found=0
  
  for cluster_def in $expected_clusters; do
    local cluster_name="${cluster_def%:*}"
    local provider="${cluster_def#*:}"
    total=$((total + 1))
    
    local exists=false
    if [ "$provider" = "k3d" ]; then
      k3d cluster list 2>/dev/null | grep -q "^$cluster_name " && exists=true
    else
      kind get clusters 2>/dev/null | grep -q "^$cluster_name$" && exists=true
    fi
    
    if $exists; then
      found=$((found + 1))
    else
      echo "  ✗ Missing cluster: $cluster_name (provider: $provider)"
      return 1
    fi
  done
  
  echo "  ✓ All $total preset clusters ready"
  return 0
}

# 验证最终状态：无孤立资源，保留预期集群
verify_final_state() {
  echo "  Preserved clusters:"
  k3d cluster list | grep -E "devops|dev|uat|prod" | sed 's/^/    /' || echo "    (none)"
  
  echo "  Test clusters (for inspection):"
  local test_api_count=$(k3d cluster list 2>/dev/null | grep -c "test-api-" || echo 0)
  test_api_count=$((test_api_count + $(kind get clusters 2>/dev/null | grep -c "test-api-" || echo 0)))
  if [ "$test_api_count" -gt 0 ]; then
    k3d cluster list 2>/dev/null | grep "test-api-" | sed 's/^/    /' || true
    kind get clusters 2>/dev/null | grep "test-api-" | sed 's/^/    /' || true
    echo "  ℹ Note: $test_api_count test-api-* clusters preserved for manual inspection"
  else
    echo "    (none)"
  fi
  
  echo "  Checking for orphaned resources..."
  local orphaned=0
  
  # 检查孤立的 test-e2e-* ArgoCD secrets（应该已删除）
  local argocd_count=$(kubectl --context k3d-devops get secrets -n argocd \
    -l "argocd.argoproj.io/secret-type=cluster" --no-headers 2>/dev/null | \
    grep -c "cluster-test-e2e-" || echo 0)
  if [ "$argocd_count" -gt 0 ]; then
    echo "  ✗ Found $argocd_count orphaned test-e2e-* ArgoCD secrets (should be deleted)"
    orphaned=$((orphaned + argocd_count))
  fi
  
  # 检查孤立的 test-e2e-* K8s 集群（应该已删除）
  local test_e2e_count=$(k3d cluster list 2>/dev/null | grep -c "test-e2e-" || echo 0)
  test_e2e_count=$((test_e2e_count + $(kind get clusters 2>/dev/null | grep -c "test-e2e-" || echo 0)))
  if [ "$test_e2e_count" -gt 0 ]; then
    echo "  ✗ Found $test_e2e_count orphaned test-e2e-* clusters (should be deleted)"
    orphaned=$((orphaned + test_e2e_count))
  fi
  
  if [ $orphaned -eq 0 ]; then
    echo "  ✓ No orphaned test-e2e-* resources (test-api-* preserved as expected)"
  else
    echo "  ✗ Found $orphaned orphaned test-e2e-* resources - TEST FAILED"
    echo "  Fix: All test-e2e-* clusters should be auto-deleted by tests"
    return 1
  fi
}

usage() {
  cat <<EOF
Usage: $0 [MODULE|all]

Modules:
  services  - Service access tests (ArgoCD, Portainer, whoami, etc.)
  ingress   - Ingress Controller health tests
  ingress_config - Ingress configuration consistency tests
  network   - Network connectivity tests
  haproxy   - HAProxy configuration tests
  clusters  - Cluster state tests
  argocd    - ArgoCD integration tests
  e2e_services - End-to-end service validation
  consistency - DB-Git-K8s consistency checks
  cluster_lifecycle - Cluster create/delete lifecycle tests
  webui     - Web UI integration tests
  all       - Run all test modules (default)

Examples:
  $0              # Run all tests
  $0 all          # Run all tests
  $0 services     # Run only service tests
  $0 network      # Run only network tests
EOF
  exit 1
}

run_test() {
  local test_file="$1"
  local test_name="$2"
  
  if [ -f "$test_file" ]; then
    echo ""
    echo "######################################################"
    echo "# $test_name"
    echo "######################################################"
    if bash "$test_file"; then
      return 0
    else
      return 1
    fi
  else
    echo "Test file not found: $test_file"
    return 1
  fi
}

target="${1:-all}"
total_failed=0
start_time=$(date +%s)

case "$target" in
  all)
    echo "=========================================="
    echo "  Kindler Test Suite - Full Run"
    echo "  (Idempotent: Clean + Bootstrap + Test)"
    echo "=========================================="
    echo "Started: $(date)"
    
    # [阶段1/5] 彻底清理环境
    echo ""
    echo "[1/5] Cleanup: Removing all clusters..."
    if ! "$SCRIPTS_DIR/clean.sh" --all; then
      echo "✗ Cleanup failed"
      exit 1
    fi
    
    # [阶段2/5] 重建标准环境
    echo ""
    echo "[2/5] Bootstrap: Creating devops cluster..."
    if ! "$SCRIPTS_DIR/bootstrap.sh"; then
      echo "✗ Bootstrap failed"
      exit 1
    fi
    
    # [阶段2.5/5] 创建预置业务集群（从 environments.csv 读取）
    echo ""
    echo "[2.5/5] Creating preset business clusters (from environments.csv)..."
    
    # 从 environments.csv 读取预置集群（排除 devops）
    preset_clusters=$(awk -F',' 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {printf "%s:%s ", $1, $2}' "$ROOT_DIR/config/environments.csv")
    
    if [ -z "$preset_clusters" ]; then
      echo "  ⚠ No preset business clusters defined in environments.csv"
    else
      i=0
      total=$(echo "$preset_clusters" | wc -w)
      for cluster_def in $preset_clusters; do
        cluster_name="${cluster_def%:*}"
        provider="${cluster_def#*:}"
        i=$((i + 1))
        echo "  [$i/$total] Creating $cluster_name (provider: $provider) - please wait (~3-5 min)..."
        if "$SCRIPTS_DIR/create_env.sh" -n "$cluster_name" -p "$provider" >/dev/null 2>&1; then
          echo "  ✓ $cluster_name created successfully"
        else
          echo "  ✗ Failed to create $cluster_name"
          echo "  Check logs for details"
          exit 1
        fi
      done
      echo "  ✓ All $total preset clusters created successfully"
    fi
    
    # [阶段3/5] 验证初始状态
    echo ""
    echo "[3/5] Verify: Checking initial environment..."
    if ! verify_initial_state; then
      echo "✗ Initial state verification failed"
      exit 1
    fi
    
    # [阶段4/5] 执行所有测试（失败立即停止）
    echo ""
    echo "[4/5] Test: Running all test suites (fail-fast)..."
    set -e  # 任何测试失败立即退出
    for test in services ingress ingress_config network haproxy clusters argocd e2e_services consistency cluster_lifecycle webui; do
      if ! run_test "$TESTS_DIR/${test}_test.sh" "${test^} Tests"; then
        total_failed=$((total_failed + 1))
        set +e
        echo ""
        echo "✗ Test suite failed: $test"
        echo "  Stopping execution (fail-fast mode)"
        echo "  Environment preserved for debugging"
        break
      fi
    done
    set +e
    
    # [阶段5/5] 验证最终状态（仅在全部通过时）
    if [ $total_failed -eq 0 ]; then
      echo ""
      echo "[5/5] Verify: Checking final environment..."
      if ! verify_final_state; then
        echo "✗ Final state verification failed"
        total_failed=$((total_failed + 1))
      fi
    else
      echo ""
      echo "[5/5] Verify: Skipped (test failed)"
    fi
    ;;
    
  services|ingress|ingress_config|network|haproxy|clusters|argocd|e2e_services|consistency|cluster_lifecycle|webui)
    run_test "$TESTS_DIR/${target}_test.sh" "${target^} Tests"
    total_failed=$?
    ;;
    
  -h|--help|help)
    usage
    ;;
    
  *)
    echo "Unknown test module: $target"
    echo ""
    usage
    ;;
esac

end_time=$(date +%s)
duration=$((end_time - start_time))

echo ""
echo "=========================================="
echo "  Final Summary"
echo "=========================================="
echo "Completed: $(date)"
echo "Duration: ${duration}s"

if [ $total_failed -eq 0 ]; then
  echo "Status: ✓ ALL TEST SUITES PASSED"
  exit 0
else
  echo "Status: ✗ $total_failed TEST SUITE(S) FAILED"
  exit 1
fi

