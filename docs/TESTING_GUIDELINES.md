# 测试指南（Testing Guidelines）

本文档提供详细的测试编写、执行和维护指南，确保所有测试遵循统一的标准和最佳实践。

## 1. 测试哲学

### 1.1 TDD 原则：红-绿-重构

**测试驱动开发（TDD）循环**：

1. **红灯（Red）**：先编写测试用例，运行失败（证明问题存在）
2. **绿灯（Green）**：编写最少代码使测试通过
3. **重构（Refactor）**：优化代码，保持测试通过

**示例流程**：
```bash
# Step 1: 编写失败的测试
cat > tests/test_db_insert.sh <<'EOF'
test_db_insert_cluster() {
  # 尝试插入集群，预期成功
  if db_insert_cluster "test" "k3d" "" 30080 19000 18090 18443 "10.101.0.2"; then
    # 验证数据库有记录
    result=$(db_query "SELECT name FROM clusters WHERE name='test'")
    if [ "$result" = "test" ]; then
      echo "✓ Test passed"
      return 0
    fi
  fi
  echo "✗ Test failed: cluster not in database"
  return 1
}
EOF

# Step 2: 运行测试（预期失败，红灯）
bash tests/test_db_insert.sh  # 失败：server_ip 列不存在

# Step 3: 修复代码（添加 server_ip 列）
# 修改 scripts/init_database.sh

# Step 4: 重新测试（绿灯）
bash tests/test_db_insert.sh  # 成功

# Step 5: 重构（保持绿灯）
# 优化 db_insert_cluster 函数
```

### 1.2 测试金字塔

```
       /\
      /  \     E2E 测试（少量，慢，脆弱）
     /----\    - WebUI 完整工作流
    /      \   - 端到端用户场景
   /--------\  
  / 集成测试 \ （中等数量，中速）
 /----------\ - 集群创建流程
/   单元测试  \ - 脚本函数测试
/--------------\ （大量，快速，稳定）
```

**测试分布建议**：
- 单元测试：70% - 快速验证函数逻辑
- 集成测试：20% - 验证组件交互
- E2E 测试：10% - 验证关键用户场景

## 2. 测试分类

### 2.1 单元测试

**定义**：测试独立的函数或模块，不依赖外部系统。

**示例**：测试 `lib_db.sh` 中的函数

```bash
#!/usr/bin/env bash
# tests/lib_db_unit_test.sh
set -Eeuo pipefail

source scripts/lib_db.sh

test_db_query_escapes_quotes() {
  local test_name="test_db_query_escapes_quotes"
  
  # Setup: 创建测试表
  db_query "CREATE TEMP TABLE test_quotes (name VARCHAR(63));"
  
  # Execute: 插入包含单引号的数据
  local value="test'cluster"
  db_query "INSERT INTO test_quotes (name) VALUES ('${value//\'/\'\'}');"
  
  # Assert: 验证数据正确存储
  local result=$(db_query "SELECT name FROM test_quotes;")
  if [ "$result" = "$value" ]; then
    echo "✓ $test_name passed"
    return 0
  else
    echo "✗ $test_name failed"
    echo "  Expected: $value"
    echo "  Actual: $result"
    return 1
  fi
  
  # Teardown: 清理测试表
  db_query "DROP TABLE test_quotes;" 2>/dev/null || true
}

# 运行测试
test_db_query_escapes_quotes
```

### 2.2 集成测试

**定义**：测试多个组件的交互，涉及真实的外部系统（数据库、K8s集群）。

**示例**：测试集群创建流程

```bash
#!/usr/bin/env bash
# tests/cluster_create_integration_test.sh
set -Eeuo pipefail

test_create_cluster_full_workflow() {
  local test_name="test_create_cluster_full_workflow"
  local cluster_name="test-int-$$"  # 使用PID避免冲突
  
  # Setup: 确保测试集群不存在
  scripts/delete_env.sh "$cluster_name" 2>/dev/null || true
  
  # Execute: 创建集群
  if ! scripts/create_env.sh -n "$cluster_name" -p k3d; then
    echo "✗ $test_name failed: cluster creation failed"
    return 1
  fi
  
  # Assert 1: 集群在 K8s 中存在
  if ! k3d cluster list | grep -q "$cluster_name"; then
    echo "✗ $test_name failed: cluster not in k3d"
    echo "  Expected: Cluster '$cluster_name' in k3d list"
    echo "  Actual: Not found"
    return 1
  fi
  
  # Assert 2: 数据库有记录
  local db_result=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
    psql -U kindler -d kindler -t -A -c "SELECT name FROM clusters WHERE name='$cluster_name';")
  if [ "$db_result" != "$cluster_name" ]; then
    echo "✗ $test_name failed: cluster not in database"
    echo "  Expected: Record for '$cluster_name'"
    echo "  Actual: $db_result"
    echo "  Fix: Check db_insert_cluster in create_env.sh"
    return 1
  fi
  
  # Assert 3: HAProxy 有路由
  if ! docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep -q "be_$cluster_name"; then
    echo "✗ $test_name failed: HAProxy route not configured"
    return 1
  fi
  
  echo "✓ $test_name passed"
  
  # Teardown: 清理测试集群
  scripts/delete_env.sh "$cluster_name"
  
  return 0
}

# 运行测试
test_create_cluster_full_workflow
```

### 2.3 E2E 测试

**定义**：测试完整的用户场景，从前端到后端到基础设施。

**示例**：WebUI 创建集群工作流

```bash
#!/usr/bin/env bash
# tests/webui_create_cluster_e2e_test.sh
set -Eeuo pipefail

test_webui_create_cluster_e2e() {
  local test_name="test_webui_create_cluster_e2e"
  local cluster_name="test-e2e-$$"
  local webui_url="http://kindler-webui.192.168.51.30.sslip.io"
  
  # Step 1: 通过 API 创建集群
  echo "[1/5] Sending create cluster request..."
  local response=$(curl -s -X POST "$webui_url/api/clusters" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$cluster_name\",\"provider\":\"k3d\"}")
  
  local task_id=$(echo "$response" | jq -r '.task_id')
  if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
    echo "✗ $test_name failed: no task_id returned"
    echo "  Response: $response"
    return 1
  fi
  
  # Step 2: 等待任务完成（最多 120 秒）
  echo "[2/5] Waiting for task completion (task_id=$task_id)..."
  for i in {1..24}; do
    task_status=$(curl -s "$webui_url/api/tasks/$task_id" | jq -r '.status')
    if [ "$task_status" = "completed" ]; then
      break
    elif [ "$task_status" = "failed" ]; then
      echo "✗ $test_name failed: task failed"
      curl -s "$webui_url/api/tasks/$task_id" | jq '.logs'
      return 1
    fi
    sleep 5
  done
  
  # Step 3: 验证集群在 API 列表中
  echo "[3/5] Checking API cluster list..."
  if ! curl -s "$webui_url/api/clusters" | jq -r '.[].name' | grep -q "$cluster_name"; then
    echo "✗ $test_name failed: cluster not in API list"
    return 1
  fi
  
  # Step 4: 验证数据库记录
  echo "[4/5] Checking database record..."
  local db_result=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
    psql -U kindler -d kindler -t -A -c "SELECT name FROM clusters WHERE name='$cluster_name';")
  if [ "$db_result" != "$cluster_name" ]; then
    echo "✗ $test_name failed: cluster not in database"
    return 1
  fi
  
  # Step 5: 验证集群实际运行
  echo "[5/5] Checking K8s cluster..."
  if ! k3d cluster list | grep -q "$cluster_name"; then
    echo "✗ $test_name failed: cluster not running"
    return 1
  fi
  
  echo "✓ $test_name passed"
  
  # Cleanup: 通过 API 删除
  curl -s -X DELETE "$webui_url/api/clusters/$cluster_name"
  sleep 10  # 等待删除完成
  
  return 0
}

# 运行测试
test_webui_create_cluster_e2e
```

## 3. 编写测试的步骤（完整模板）

```bash
#!/usr/bin/env bash
# tests/template_test.sh
set -Eeuo pipefail

# ==================================================
# 测试模板：数据库插入集群
# ==================================================

# 全局配置
TEST_NAME="db_insert_cluster"
TEMP_FILES=()

# 清理函数（确保资源释放）
cleanup() {
  local exit_code=$?
  echo "[CLEANUP] Cleaning up test resources..."
  
  # 清理测试数据
  if [ -n "${TEST_CLUSTER_NAME:-}" ]; then
    db_query "DELETE FROM clusters WHERE name='$TEST_CLUSTER_NAME';" 2>/dev/null || true
  fi
  
  # 清理临时文件
  for file in "${TEMP_FILES[@]}"; do
    rm -f "$file" 2>/dev/null || true
  done
  
  exit $exit_code
}

# 设置清理钩子
trap cleanup EXIT INT TERM

# ==================================================
# Step 1: 定义测试函数
# ==================================================
test_db_insert_cluster() {
  local test_name="test_db_insert_cluster"
  echo "[TEST] Running: $test_name"
  
  # ==================================================
  # Step 2: Setup - 准备测试环境
  # ==================================================
  TEST_CLUSTER_NAME="test-cluster-$$"
  local provider="k3d"
  local subnet="10.200.0.0/16"
  local node_port=30080
  local pf_port=19000
  local http_port=18090
  local https_port=18443
  local server_ip="10.200.0.2"
  
  # 确保测试数据不存在
  db_query "DELETE FROM clusters WHERE name='$TEST_CLUSTER_NAME';" 2>/dev/null || true
  
  # ==================================================
  # Step 3: Execute - 执行被测试的操作
  # ==================================================
  echo "  [EXEC] Inserting cluster '$TEST_CLUSTER_NAME'..."
  if ! db_insert_cluster "$TEST_CLUSTER_NAME" "$provider" "$subnet" \
      "$node_port" "$pf_port" "$http_port" "$https_port" "$server_ip" 2>/tmp/test_error.log; then
    # 插入失败，输出详细错误
    echo "✗ $test_name failed: db_insert_cluster returned non-zero"
    echo "  Expected: Successful insert"
    echo "  Actual: Insert failed"
    echo "  Context:"
    echo "    - cluster: $TEST_CLUSTER_NAME"
    echo "    - provider: $provider"
    echo "    - subnet: $subnet"
    echo "  Error log: $(cat /tmp/test_error.log 2>/dev/null || echo 'no log')"
    echo "  Fix: Check if server_ip column exists in clusters table"
    echo "  Command: kubectl exec postgresql-0 -- psql -U kindler -d kindler -c '\d clusters'"
    return 1
  fi
  
  # ==================================================
  # Step 4: Assert - 验证结果
  # ==================================================
  echo "  [ASSERT] Verifying database record..."
  
  # Assert 1: 记录存在
  local actual_name=$(db_query "SELECT name FROM clusters WHERE name='$TEST_CLUSTER_NAME';")
  if [ "$actual_name" != "$TEST_CLUSTER_NAME" ]; then
    echo "✗ $test_name failed: cluster not found in database"
    echo "  Expected: $TEST_CLUSTER_NAME"
    echo "  Actual: $actual_name"
    echo "  Context: Record should exist after insert"
    echo "  Fix: Check db_insert_cluster SQL statement"
    return 1
  fi
  
  # Assert 2: 字段值正确
  local actual_provider=$(db_query "SELECT provider FROM clusters WHERE name='$TEST_CLUSTER_NAME';")
  if [ "$actual_provider" != "$provider" ]; then
    echo "✗ $test_name failed: provider mismatch"
    echo "  Expected: $provider"
    echo "  Actual: $actual_provider"
    return 1
  fi
  
  # Assert 3: server_ip 正确
  local actual_ip=$(db_query "SELECT server_ip FROM clusters WHERE name='$TEST_CLUSTER_NAME';")
  if [ "$actual_ip" != "$server_ip" ]; then
    echo "✗ $test_name failed: server_ip mismatch"
    echo "  Expected: $server_ip"
    echo "  Actual: $actual_ip"
    echo "  Context: server_ip column might not exist or not populated"
    echo "  Fix: Verify init_database.sh creates server_ip column"
    return 1
  fi
  
  # ==================================================
  # Step 5: Teardown - 清理测试数据（通过 trap 自动执行）
  # ==================================================
  # cleanup() 函数会在脚本退出时自动调用
  
  echo "✓ $test_name passed"
  return 0
}

# ==================================================
# 主函数：运行所有测试
# ==================================================
main() {
  local failed=0
  
  # 前置检查
  echo "[SETUP] Checking prerequisites..."
  if ! db_is_available; then
    echo "✗ Database not available, skipping tests"
    exit 2  # 返回 2 表示跳过
  fi
  
  # 运行测试
  test_db_insert_cluster || failed=$((failed + 1))
  
  # 汇总结果
  echo ""
  echo "========================================"
  if [ $failed -eq 0 ]; then
    echo "✓ All tests passed"
    exit 0
  else
    echo "✗ $failed test(s) failed"
    exit 1
  fi
}

# 执行主函数
main "$@"
```

## 4. 诊断输出标准

### 4.1 失败输出模板

```bash
# 完整诊断输出模板
cat <<EOF
✗ Test Failed: <test_name>
  Expected: <expected_value>
  Actual: <actual_value>
  Context:
    - cluster: <cluster_name>
    - provider: <provider>
    - parameter: <value>
    - config_file: <path>
  Error Details: <error_message>
  Fix Suggestion: <how_to_fix>
  Debug Commands:
    1. <command_to_check_state>
    2. <command_to_view_logs>
    3. <command_to_verify_config>
  Related:
    - AGENTS.md#案例-X
    - docs/TROUBLESHOOTING.md#<section>
EOF
```

### 4.2 实际示例

```bash
# 数据库插入失败
echo "✗ Test Failed: test_db_insert_cluster_with_server_ip"
echo "  Expected: Cluster 'dev' record in database with server_ip='10.101.0.2'"
echo "  Actual: No records found in clusters table"
echo "  Context:"
echo "    - cluster: dev"
echo "    - provider: k3d"
echo "    - node_port: 30080"
echo "    - server_ip: 10.101.0.2"
echo "  Error Details: ERROR:  column \"server_ip\" does not exist"
echo "  Fix Suggestion: Add server_ip column to clusters table in init_database.sh"
echo "  Debug Commands:"
echo "    1. kubectl --context k3d-devops -n paas exec postgresql-0 -- psql -U kindler -d kindler -c '\d clusters'"
echo "    2. cat scripts/init_database.sh | grep -A 10 'CREATE TABLE clusters'"
echo "    3. grep 'server_ip' scripts/lib_db.sh"
echo "  Related:"
echo "    - AGENTS.md#案例-5：数据库表结构不一致"
echo "    - docs/TESTING_GUIDELINES.md#测试固化原则"
```

### 4.3 成功输出标准

```bash
# 简洁的成功输出
echo "✓ test_db_insert_cluster passed (1.2s)"

# 详细的成功输出（调试模式）
if [ "${VERBOSE:-}" = "1" ]; then
  cat <<EOF
✓ Test Passed: test_db_insert_cluster
  Duration: 1.2s
  Assertions: 3 passed
    - Cluster record exists
    - Provider matches
    - Server IP correct
  Cleanup: Complete
EOF
fi
```

## 5. 测试执行规范

### 5.1 错误处理

```bash
#!/usr/bin/env bash
# 严格模式：任何错误立即退出
set -Eeuo pipefail

# IFS 设置（避免单词分割问题）
IFS=$'\n\t'

# 错误处理函数
err_handler() {
  local exit_code=$?
  local line_no=$1
  echo "✗ Error on line $line_no (exit code: $exit_code)"
  echo "  Command: ${BASH_COMMAND}"
  exit $exit_code
}

# 注册错误处理
trap 'err_handler ${LINENO}' ERR
```

### 5.2 返回码约定

| 返回码 | 含义 | 使用场景 |
|--------|------|----------|
| 0 | 成功 | 所有测试通过 |
| 1 | 失败 | 至少一个测试失败 |
| 2 | 跳过 | 前置条件不满足（如数据库不可用） |
| 3-99 | 保留 | 未来扩展使用 |
| 100+ | 自定义 | 特定错误类型 |

```bash
# 示例：根据前置条件决定是否跳过
if ! db_is_available; then
  echo "⚠ Database not available, skipping tests"
  exit 2  # 返回 2 表示跳过
fi

# 示例：自定义错误码
if ! cluster_exists "devops"; then
  echo "✗ devops cluster not found (critical error)"
  exit 100  # 自定义错误码
fi
```

### 5.3 测试输出格式

```bash
# 标准输出格式（支持自动解析）
echo "[PASS] test_db_insert_cluster (1.2s)"
echo "[FAIL] test_db_query_nonexistent (0.8s)"
echo "[SKIP] test_api_create_cluster (database unavailable)"

# TAP 格式（Test Anything Protocol）
cat <<EOF
1..3
ok 1 - test_db_insert_cluster
not ok 2 - test_db_query_nonexistent
  ---
  expected: cluster record
  actual: no record
  ...
ok 3 - test_db_delete_cluster # SKIP database unavailable
EOF

# JSON 格式（机器可读）
cat <<EOF
{
  "test": "test_db_insert_cluster",
  "status": "passed",
  "duration": 1.2,
  "assertions": 3
}
EOF
```

## 6. 常见测试场景示例

### 6.1 数据库 CRUD 测试

详见 `tests/db_operations_test.sh`（完整示例）

### 6.2 API Endpoint 测试

```bash
#!/usr/bin/env bash
# tests/api_endpoint_test.sh

test_api_list_clusters() {
  local webui_url="http://kindler-webui.192.168.51.30.sslip.io"
  
  # Execute
  local response=$(curl -s -w "\n%{http_code}" "$webui_url/api/clusters")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  # Assert: 状态码 200
  if [ "$status" != "200" ]; then
    echo "✗ test_api_list_clusters failed: wrong status code"
    echo "  Expected: 200"
    echo "  Actual: $status"
    echo "  Body: $body"
    return 1
  fi
  
  # Assert: 返回 JSON 数组
  if ! echo "$body" | jq -e '. | type == "array"' >/dev/null; then
    echo "✗ test_api_list_clusters failed: response not an array"
    echo "  Body: $body"
    return 1
  fi
  
  # Assert: 包含 devops 集群
  if ! echo "$body" | jq -e '.[] | select(.name == "devops")' >/dev/null; then
    echo "✗ test_api_list_clusters failed: devops cluster missing"
    echo "  Body: $body"
    return 1
  fi
  
  echo "✓ test_api_list_clusters passed"
  return 0
}
```

### 6.3 并发操作测试

```bash
#!/usr/bin/env bash
# tests/concurrent_test.sh

test_concurrent_cluster_creation() {
  local test_name="test_concurrent_cluster_creation"
  local num_clusters=3
  local pids=()
  
  # 启动并发创建
  for i in $(seq 1 $num_clusters); do
    (
      cluster_name="test-concurrent-$i-$$"
      scripts/create_env.sh -n "$cluster_name" -p k3d >/dev/null 2>&1
      echo "$cluster_name"
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
  
  # 验证结果
  if [ $failed -gt 0 ]; then
    echo "✗ $test_name failed: $failed/$num_clusters creations failed"
    return 1
  fi
  
  # 验证数据库一致性
  local db_count=$(db_query "SELECT COUNT(*) FROM clusters WHERE name LIKE 'test-concurrent-%';")
  if [ "$db_count" != "$num_clusters" ]; then
    echo "✗ $test_name failed: database inconsistency"
    echo "  Expected: $num_clusters records"
    echo "  Actual: $db_count records"
    return 1
  fi
  
  echo "✓ $test_name passed"
  
  # Cleanup
  for i in $(seq 1 $num_clusters); do
    scripts/delete_env.sh "test-concurrent-$i-$$" 2>/dev/null || true
  done
  
  return 0
}
```

## 7. 测试集成与自动化

### 7.1 集成到 run_tests.sh

```bash
# tests/run_tests.sh

# 注册新测试模块
TESTS=(
  "tests/db_operations_test.sh"
  "tests/webui_api_test.sh"
  "tests/cluster_lifecycle_test.sh"
  # ... 其他测试
)

# 执行测试
for test_script in "${TESTS[@]}"; do
  echo "[RUN] $test_script"
  if bash "$test_script"; then
    echo "[PASS] $test_script"
  else
    exit_code=$?
    if [ $exit_code -eq 2 ]; then
      echo "[SKIP] $test_script"
    else
      echo "[FAIL] $test_script"
      failed=$((failed + 1))
    fi
  fi
done
```

### 7.2 CI/CD 集成

```yaml
# .github/workflows/test.yml
name: Regression Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Bootstrap Environment
        run: |
          scripts/bootstrap.sh
      
      - name: Run Tests
        run: |
          tests/run_tests.sh all
      
      - name: Upload Test Results
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: test-results
          path: /tmp/test_*.log
```

## 8. 测试维护

### 8.1 定期审查

- **月度审查**：检查测试覆盖率，识别遗漏
- **季度审查**：更新测试用例，适应新功能
- **年度审查**：重构测试代码，优化性能

### 8.2 测试指标

```bash
# 生成测试覆盖率报告
scripts/generate_test_coverage.sh

# 输出示例：
# Module                 Coverage    Tests
# ====================================================
# scripts/lib_db.sh      85%         12 tests
# scripts/create_env.sh  90%         8 tests
# webui/backend/api/     70%         15 tests
# ====================================================
# Total Coverage:        82%         35 tests
```

### 8.3 测试优化

**优化慢速测试**：
```bash
# Before: 30s
test_cluster_create() {
  scripts/create_env.sh -n test
  sleep 60  # 等待集群就绪
  # ... assertions
}

# After: 10s
test_cluster_create() {
  scripts/create_env.sh -n test
  # 主动轮询代替固定等待
  wait_for_cluster_ready "test" 60  # 最多 60s
  # ... assertions
}
```

## 9. 常见问题与解决方案

### 9.1 测试不稳定（Flaky Tests）

**问题**：测试时而通过时而失败

**原因**：
- 异步操作未等待完成
- 资源清理不彻底
- 硬编码时间假设

**解决方案**：
```bash
# Bad: 固定等待时间
sleep 30  # 集群可能需要更长时间

# Good: 轮询 + 超时
wait_for_cluster_ready() {
  local cluster=$1
  local timeout=${2:-60}
  local elapsed=0
  
  while [ $elapsed -lt $timeout ]; do
    if kubectl --context "k3d-$cluster" get nodes &>/dev/null; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  echo "✗ Timeout waiting for cluster $cluster" >&2
  return 1
}
```

### 9.2 测试依赖问题

**问题**：测试 B 依赖测试 A 的副作用

**解决方案**：
```bash
# Bad: 依赖其他测试
test_b() {
  # 假设 test_a 已创建集群 'test'
  kubectl --context k3d-test get nodes
}

# Good: 独立设置
test_b() {
  # 自己创建需要的环境
  setup_test_cluster "test-b-$$"
  kubectl --context "k3d-test-b-$$" get nodes
  cleanup_test_cluster "test-b-$$"
}
```

### 9.3 测试数据污染

**问题**：测试失败后残留数据影响后续测试

**解决方案**：
```bash
# 使用 trap 确保清理
cleanup() {
  local exit_code=$?
  # 清理逻辑，即使测试失败也会执行
  scripts/delete_env.sh "$TEST_CLUSTER" 2>/dev/null || true
  exit $exit_code
}

trap cleanup EXIT INT TERM
```

## 10. 总结

### 10.1 测试编写检查清单

- [ ] 测试函数命名清晰（`test_<module>_<scenario>`）
- [ ] 包含 Setup / Execute / Assert / Teardown
- [ ] 失败时输出详细诊断信息（Expected/Actual/Context/Fix）
- [ ] 使用 `set -Eeuo pipefail` 严格模式
- [ ] 实现 cleanup 函数并注册 trap
- [ ] 返回正确的退出码（0/1/2）
- [ ] 测试独立运行，不依赖其他测试
- [ ] 资源使用唯一标识（避免冲突）
- [ ] 集成到 `tests/run_tests.sh`
- [ ] 文档化测试目的和预期行为

### 10.2 快速参考

```bash
# 创建新测试文件
cp tests/template_test.sh tests/my_new_test.sh

# 单独运行测试
bash tests/my_new_test.sh

# 运行所有测试
tests/run_tests.sh all

# 运行特定模块测试
tests/run_tests.sh db

# 详细输出模式
VERBOSE=1 tests/run_tests.sh all

# 生成测试报告
tests/run_tests.sh all > /tmp/test_report_$(date +%s).log 2>&1
```

### 10.3 进一步阅读

- [AGENTS.md#测试固化原则](../AGENTS.md#测试固化原则2025-10-新增) - 测试规则和历史教训
- [tests/README.md](../tests/README.md) - 测试套件说明
- [TAP Protocol](https://testanything.org/) - 标准测试输出格式
- [Bash Best Practices](https://mywiki.wooledge.org/BashGuide/Practices) - Shell 脚本最佳实践

---

**最后更新**：2025-10-24  
**维护者**：项目团队  
**反馈**：如有问题或建议，请提交 Issue


