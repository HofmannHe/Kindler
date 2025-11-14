#!/usr/bin/env bash
# 数据库操作测试套件
# 测试 PostgreSQL 数据库的 CRUD 操作

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

# 全局变量
TEST_CLUSTER_PREFIX="test-db-$$"
FAILED_TESTS=0
PASSED_TESTS=0
SKIPPED_TESTS=0

# 清理函数
cleanup() {
  local exit_code=$?
  echo ""
  echo "[CLEANUP] Removing test data..."
  
  # 清理所有测试集群记录
  db_query "DELETE FROM clusters WHERE name LIKE '$TEST_CLUSTER_PREFIX%';" 2>/dev/null || true
  
  exit $exit_code
}

trap cleanup EXIT INT TERM

# ==================================================
# 测试用例 1：验证表结构
# ==================================================
test_db_table_schema() {
  local test_name="test_db_table_schema"
  echo "[TEST] $test_name"
  
  # 获取表结构
  local schema=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
    psql -U kindler -d kindler -c "\d clusters" 2>/dev/null)
  
  # Assert 1: server_ip 列存在
  if ! echo "$schema" | grep -q "server_ip"; then
    cat <<EOF
✗ Test Failed: $test_name
  Expected: Column 'server_ip' exists in clusters table
  Actual: Column not found
  Context:
    - table: clusters
    - database: kindler
  Fix Suggestion: Add server_ip column in tools/db/init_database.sh
  Debug Command: kubectl --context k3d-devops -n paas exec postgresql-0 -- psql -U kindler -d kindler -c '\d clusters'
  Related: AGENTS.md#案例-5
EOF
    return 1
  fi
  
  # Assert 2: 必需列都存在
  local required_columns=("name" "provider" "node_port" "pf_port" "http_port" "https_port" "created_at" "updated_at")
  for col in "${required_columns[@]}"; do
    if ! echo "$schema" | grep -q "$col"; then
      echo "✗ $test_name failed: required column '$col' missing"
      return 1
    fi
  done
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 测试用例 2：插入 k3d 集群（带 subnet + server_ip）
# ==================================================
test_db_insert_k3d_cluster() {
  local test_name="test_db_insert_k3d_cluster"
  echo "[TEST] $test_name"
  
  # Setup
  local cluster_name="${TEST_CLUSTER_PREFIX}-k3d"
  local provider="k3d"
  local subnet="10.200.0.0/16"
  local node_port=30080
  local pf_port=19000
  local http_port=18090
  local https_port=18443
  local server_ip="10.200.0.2"
  
  # 确保测试数据不存在
  db_query "DELETE FROM clusters WHERE name='$cluster_name';" 2>/dev/null || true
  
  # Execute
  if ! db_insert_cluster "$cluster_name" "$provider" "$subnet" \
      "$node_port" "$pf_port" "$http_port" "$https_port" "$server_ip" 2>/tmp/test_db_insert_error.log; then
    cat <<EOF
✗ Test Failed: $test_name
  Expected: Successful insert of k3d cluster with subnet and server_ip
  Actual: db_insert_cluster failed
  Context:
    - cluster: $cluster_name
    - provider: $provider
    - subnet: $subnet
    - server_ip: $server_ip
  Error: $(cat /tmp/test_db_insert_error.log 2>/dev/null || echo 'no error log')
  Fix Suggestion: Check db_insert_cluster implementation in scripts/lib/lib_sqlite.sh
  Debug Command: kubectl --context k3d-devops -n paas exec postgresql-0 -- psql -U kindler -d kindler -c "SELECT * FROM clusters WHERE name='$cluster_name';"
EOF
    return 1
  fi
  
  # Assert 1: 记录存在
  local actual_name=$(db_query "SELECT name FROM clusters WHERE name='$cluster_name';")
  if [ "$actual_name" != "$cluster_name" ]; then
    echo "✗ $test_name failed: cluster not found in database"
    echo "  Expected: $cluster_name"
    echo "  Actual: $actual_name"
    return 1
  fi
  
  # Assert 2: subnet 正确
  local actual_subnet=$(db_query "SELECT subnet::text FROM clusters WHERE name='$cluster_name';")
  if [ "$actual_subnet" != "$subnet" ]; then
    echo "✗ $test_name failed: subnet mismatch"
    echo "  Expected: $subnet"
    echo "  Actual: $actual_subnet"
    return 1
  fi
  
  # Assert 3: server_ip 正确
  local actual_ip=$(db_query "SELECT server_ip FROM clusters WHERE name='$cluster_name';")
  if [ "$actual_ip" != "$server_ip" ]; then
    cat <<EOF
✗ Test Failed: $test_name
  Expected: server_ip = $server_ip
  Actual: server_ip = $actual_ip
  Context:
    - cluster: $cluster_name
    - provider: $provider
  Fix Suggestion: Check if server_ip column exists and is populated correctly
EOF
    return 1
  fi
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 测试用例 3：插入 kind 集群（无 subnet）
# ==================================================
test_db_insert_kind_cluster() {
  local test_name="test_db_insert_kind_cluster"
  echo "[TEST] $test_name"
  
  # Setup
  local cluster_name="${TEST_CLUSTER_PREFIX}-kind"
  local provider="kind"
  local subnet=""  # kind 集群不需要 subnet
  local node_port=30080
  local pf_port=19010
  local http_port=18093
  local https_port=18446
  local server_ip="172.19.0.2"
  
  db_query "DELETE FROM clusters WHERE name='$cluster_name';" 2>/dev/null || true
  
  # Execute
  if ! db_insert_cluster "$cluster_name" "$provider" "$subnet" \
      "$node_port" "$pf_port" "$http_port" "$https_port" "$server_ip"; then
    echo "✗ $test_name failed: db_insert_cluster failed for kind cluster"
    return 1
  fi
  
  # Assert: subnet 应为 NULL
  local actual_subnet=$(db_query "SELECT subnet::text FROM clusters WHERE name='$cluster_name';")
  if [ -n "$actual_subnet" ]; then
    echo "✗ $test_name failed: subnet should be NULL for kind cluster"
    echo "  Expected: (empty)"
    echo "  Actual: $actual_subnet"
    return 1
  fi
  
  # Assert: 其他字段正确
  local actual_provider=$(db_query "SELECT provider FROM clusters WHERE name='$cluster_name';")
  if [ "$actual_provider" != "$provider" ]; then
    echo "✗ $test_name failed: provider mismatch"
    return 1
  fi
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 测试用例 4：查询集群记录
# ==================================================
test_db_query_cluster() {
  local test_name="test_db_query_cluster"
  echo "[TEST] $test_name"
  
  # Setup: 确保有测试数据
  local cluster_name="${TEST_CLUSTER_PREFIX}-query"
  db_query "DELETE FROM clusters WHERE name='$cluster_name';" 2>/dev/null || true
  db_insert_cluster "$cluster_name" "k3d" "10.201.0.0/16" 30080 19000 18090 18443 "10.201.0.2"
  
  # Execute & Assert 1: 按名称查询
  local result=$(db_query "SELECT name FROM clusters WHERE name='$cluster_name';")
  if [ "$result" != "$cluster_name" ]; then
    echo "✗ $test_name failed: query by name failed"
    return 1
  fi
  
  # Execute & Assert 2: 按 provider 查询
  local count=$(db_query "SELECT COUNT(*) FROM clusters WHERE provider='k3d';")
  if [ "$count" -lt 1 ]; then
    echo "✗ $test_name failed: query by provider returned no results"
    return 1
  fi
  
  # Execute & Assert 3: 查询所有字段
  local full_record=$(db_query "SELECT name, provider, node_port FROM clusters WHERE name='$cluster_name';")
  if ! echo "$full_record" | grep -q "$cluster_name"; then
    echo "✗ $test_name failed: full record query failed"
    return 1
  fi
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 测试用例 5：更新集群记录
# ==================================================
test_db_update_cluster() {
  local test_name="test_db_update_cluster"
  echo "[TEST] $test_name"
  
  # Setup: 插入初始记录
  local cluster_name="${TEST_CLUSTER_PREFIX}-update"
  db_query "DELETE FROM clusters WHERE name='$cluster_name';" 2>/dev/null || true
  db_insert_cluster "$cluster_name" "k3d" "10.202.0.0/16" 30080 19000 18090 18443 "10.202.0.2"
  
  # Execute: 更新 http_port（使用 UPSERT）
  local new_http_port=18099
  db_insert_cluster "$cluster_name" "k3d" "10.202.0.0/16" 30080 19000 "$new_http_port" 18443 "10.202.0.2"
  
  # Assert: http_port 已更新
  local actual_port=$(db_query "SELECT http_port FROM clusters WHERE name='$cluster_name';")
  if [ "$actual_port" != "$new_http_port" ]; then
    echo "✗ $test_name failed: http_port not updated"
    echo "  Expected: $new_http_port"
    echo "  Actual: $actual_port"
    return 1
  fi
  
  # Assert: updated_at 已更新（应该不等于 created_at）
  local created_at=$(db_query "SELECT created_at FROM clusters WHERE name='$cluster_name';")
  local updated_at=$(db_query "SELECT updated_at FROM clusters WHERE name='$cluster_name';")
  
  # 等待 1 秒确保时间戳不同
  sleep 1
  db_insert_cluster "$cluster_name" "k3d" "10.202.0.0/16" 30080 19000 "$new_http_port" 18443 "10.202.0.2"
  local new_updated_at=$(db_query "SELECT updated_at FROM clusters WHERE name='$cluster_name';")
  
  if [ "$updated_at" = "$new_updated_at" ]; then
    echo "✗ $test_name failed: updated_at not refreshed"
    return 1
  fi
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 测试用例 6：删除集群记录
# ==================================================
test_db_delete_cluster() {
  local test_name="test_db_delete_cluster"
  echo "[TEST] $test_name"
  
  # Setup
  local cluster_name="${TEST_CLUSTER_PREFIX}-delete"
  db_query "DELETE FROM clusters WHERE name='$cluster_name';" 2>/dev/null || true
  db_insert_cluster "$cluster_name" "k3d" "10.203.0.0/16" 30080 19000 18090 18443 "10.203.0.2"
  
  # 确认记录存在
  local before_count=$(db_query "SELECT COUNT(*) FROM clusters WHERE name='$cluster_name';")
  if [ "$before_count" != "1" ]; then
    echo "✗ $test_name failed: setup failed, record not created"
    return 1
  fi
  
  # Execute: 删除记录
  if ! db_query "DELETE FROM clusters WHERE name='$cluster_name';"; then
    echo "✗ $test_name failed: DELETE query failed"
    return 1
  fi
  
  # Assert: 记录已删除
  local after_count=$(db_query "SELECT COUNT(*) FROM clusters WHERE name='$cluster_name';")
  if [ "$after_count" != "0" ]; then
    echo "✗ $test_name failed: record not deleted"
    echo "  Expected count: 0"
    echo "  Actual count: $after_count"
    return 1
  fi
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 测试用例 7：并发插入测试
# ==================================================
test_db_concurrent_inserts() {
  local test_name="test_db_concurrent_inserts"
  echo "[TEST] $test_name"
  
  # Setup
  local num_clusters=5
  local pids=()
  
  # 清理旧数据
  for i in $(seq 1 $num_clusters); do
    db_query "DELETE FROM clusters WHERE name='${TEST_CLUSTER_PREFIX}-concurrent-$i';" 2>/dev/null || true
  done
  
  # Execute: 并发插入
  for i in $(seq 1 $num_clusters); do
    (
      cluster_name="${TEST_CLUSTER_PREFIX}-concurrent-$i"
      subnet="10.20$i.0.0/16"
      server_ip="10.20$i.0.2"
      db_insert_cluster "$cluster_name" "k3d" "$subnet" 30080 19000 18090 18443 "$server_ip" >/dev/null 2>&1
    ) &
    pids+=($!)
  done
  
  # 等待所有任务完成
  local failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=$((failed + 1))
    fi
  done
  
  if [ $failed -gt 0 ]; then
    echo "✗ $test_name failed: $failed/$num_clusters inserts failed"
    return 1
  fi
  
  # Assert: 所有记录都已插入
  local actual_count=$(db_query "SELECT COUNT(*) FROM clusters WHERE name LIKE '${TEST_CLUSTER_PREFIX}-concurrent-%';")
  if [ "$actual_count" != "$num_clusters" ]; then
    cat <<EOF
✗ Test Failed: $test_name
  Expected: $num_clusters concurrent inserts
  Actual: $actual_count records in database
  Context:
    - concurrent_operations: $num_clusters
    - failed_inserts: $failed
  Fix Suggestion: Check for database locking issues or race conditions
EOF
    return 1
  fi
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 测试用例 8：重复插入测试（UPSERT）
# ==================================================
test_db_duplicate_insert() {
  local test_name="test_db_duplicate_insert"
  echo "[TEST] $test_name"
  
  # Setup
  local cluster_name="${TEST_CLUSTER_PREFIX}-duplicate"
  db_query "DELETE FROM clusters WHERE name='$cluster_name';" 2>/dev/null || true
  
  # Execute 1: 首次插入
  db_insert_cluster "$cluster_name" "k3d" "10.204.0.0/16" 30080 19000 18090 18443 "10.204.0.2"
  
  # Execute 2: 重复插入（应该 UPSERT）
  db_insert_cluster "$cluster_name" "k3d" "10.204.0.0/16" 30080 19000 18091 18443 "10.204.0.2"
  
  # Assert 1: 只有一条记录
  local count=$(db_query "SELECT COUNT(*) FROM clusters WHERE name='$cluster_name';")
  if [ "$count" != "1" ]; then
    echo "✗ $test_name failed: duplicate record created"
    echo "  Expected count: 1"
    echo "  Actual count: $count"
    return 1
  fi
  
  # Assert 2: 值已更新（http_port 从 18090 变为 18091）
  local actual_port=$(db_query "SELECT http_port FROM clusters WHERE name='$cluster_name';")
  if [ "$actual_port" != "18091" ]; then
    echo "✗ $test_name failed: UPSERT did not update value"
    echo "  Expected http_port: 18091"
    echo "  Actual http_port: $actual_port"
    return 1
  fi
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 主函数：运行所有测试
# ==================================================
main() {
  echo "========================================"
  echo "  Database Operations Test Suite"
  echo "========================================"
  echo ""
  
  # 前置检查
  echo "[SETUP] Checking prerequisites..."
  if ! db_is_available; then
    cat <<EOF
⚠ Test Suite Skipped: Database not available
  Context:
    - context: k3d-devops
    - namespace: paas
    - pod: postgresql-0
  Fix Suggestion: Ensure devops cluster is running and PostgreSQL is ready
  Debug Commands:
    1. kubectl --context k3d-devops get pods -n paas
    2. kubectl --context k3d-devops logs -n paas postgresql-0
    3. scripts/bootstrap.sh
EOF
    exit 2
  fi
  echo "✓ Database available"
  echo ""
  
  # 运行测试
  test_db_table_schema || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  test_db_insert_k3d_cluster || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  test_db_insert_kind_cluster || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  test_db_query_cluster || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  test_db_update_cluster || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  test_db_delete_cluster || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  test_db_concurrent_inserts || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  test_db_duplicate_insert || FAILED_TESTS=$((FAILED_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1 - FAILED_TESTS))
  
  # 汇总结果
  echo ""
  echo "========================================"
  echo "  Test Results"
  echo "========================================"
  echo "Passed:  $PASSED_TESTS"
  echo "Failed:  $FAILED_TESTS"
  echo "Skipped: $SKIPPED_TESTS"
  echo "========================================"
  
  if [ $FAILED_TESTS -eq 0 ]; then
    echo "✓ All tests passed"
    exit 0
  else
    echo "✗ Some tests failed"
    exit 1
  fi
}

# 执行主函数
main "$@"
