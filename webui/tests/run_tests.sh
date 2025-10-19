#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

echo "=== Kindler Web GUI Test Suite ==="
echo

# Check if services are running
check_services() {
  echo "Checking if Web GUI services are running..."
  
  if ! docker ps | grep -q kindler-webui-backend; then
    echo "❌ Backend container not running"
    return 1
  fi
  
  if ! docker ps | grep -q kindler-webui-frontend; then
    echo "❌ Frontend container not running"
    return 1
  fi
  
  echo "✅ Services are running"
  return 0
}

# Run API tests
run_api_tests() {
  echo
  echo "=== Running API Tests ==="
  cd "$SCRIPT_DIR"
  pytest api/ -v --tb=short
}

# Run E2E tests (basic only, no full workflow)
run_e2e_tests_basic() {
  echo
  echo "=== Running E2E Tests (Basic) ==="
  cd "$SCRIPT_DIR"
  pytest e2e/ -v --tb=short -m "not slow"
}

# Run E2E tests (full workflow)
run_e2e_tests_full() {
  echo
  echo "=== Running E2E Tests (Full Workflow) ==="
  echo "⚠️  This will create and delete test clusters"
  cd "$SCRIPT_DIR"
  E2E_FULL_TEST=1 pytest e2e/ -v --tb=short
}

# Main
main() {
  local test_type="${1:-all}"
  
  case "$test_type" in
    api)
      run_api_tests
      ;;
    e2e-basic)
      if ! check_services; then
        echo "Please start services first: docker compose -f compose/infrastructure/docker-compose.yml up -d"
        exit 1
      fi
      run_e2e_tests_basic
      ;;
    e2e-full)
      if ! check_services; then
        echo "Please start services first: docker compose -f compose/infrastructure/docker-compose.yml up -d"
        exit 1
      fi
      run_e2e_tests_full
      ;;
    all)
      run_api_tests
      if check_services; then
        run_e2e_tests_basic
      else
        echo "⚠️  Skipping E2E tests (services not running)"
      fi
      ;;
    *)
      echo "Usage: $0 [api|e2e-basic|e2e-full|all]"
      exit 1
      ;;
  esac
  
  echo
  echo "=== Test Suite Complete ==="
}

main "$@"

