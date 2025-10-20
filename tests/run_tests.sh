#!/usr/bin/env bash
# 测试运行器
# 统一入口运行所有或指定的测试模块

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$ROOT_DIR/tests"

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
    echo "=========================================="
    echo "Started: $(date)"
    
    for test in services ingress ingress_config network haproxy clusters argocd e2e_services consistency cluster_lifecycle; do
      if ! run_test "$TESTS_DIR/${test}_test.sh" "${test^} Tests"; then
        total_failed=$((total_failed + 1))
      fi
    done
    ;;
    
  services|ingress|ingress_config|network|haproxy|clusters|argocd|e2e_services|consistency|cluster_lifecycle)
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

