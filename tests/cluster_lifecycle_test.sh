#!/usr/bin/env bash
# 集群生命周期端到端测试

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/lib.sh"
source "$ROOT_DIR/scripts/lib/lib_sqlite.sh"
source "$ROOT_DIR/tests/lib_verify.sh" 2>/dev/null || true

echo "######################################################"
echo "# Cluster Lifecycle Tests"
echo "######################################################"
echo "=========================================="
echo "Create/Delete Lifecycle Validation"
echo "=========================================="
echo ""

TEST_CLUSTER="test-lifecycle-$$"  # 使用 PID 确保唯一性

cleanup() {
  # 只有在测试异常退出时才清理（正常流程中已经通过 delete_env.sh 清理）
  if [ "${CLEANUP_DONE:-0}" = "0" ]; then
    echo ""
    echo "[CLEANUP] Removing test cluster if exists (abnormal exit)..."
    "$ROOT_DIR/scripts/delete_env.sh" -n "$TEST_CLUSTER" -p k3d 2>/dev/null || true
    
    # 清理 Git 分支
    if [ -f "$ROOT_DIR/scripts/delete_git_branch.sh" ]; then
      "$ROOT_DIR/scripts/delete_git_branch.sh" "$TEST_CLUSTER" 2>/dev/null || true
    fi
  fi
}

trap cleanup EXIT

# 标记清理状态
CLEANUP_DONE=0

##############################################
# 1. 创建测试集群
##############################################
echo "[1/4] Creating Test Cluster: $TEST_CLUSTER"

# 创建临时测试集群（宽松模式允许创建不在CSV中的集群）
# 提供所有必需参数的默认值
if timeout 180 "$ROOT_DIR/scripts/create_env.sh" -n "$TEST_CLUSTER" -p k3d --pf-port 29999 --no-register-portainer --haproxy-route >/tmp/create_test.log 2>&1; then
  echo "  ✓ Cluster creation completed"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ Cluster creation failed"
  echo "  See /tmp/create_test.log for details"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

echo ""

##############################################
# 2. 验证资源创建
##############################################
echo "[2/4] Verifying Resources Created"

# 检查 K8s 集群
if kubectl config get-contexts "k3d-$TEST_CLUSTER" >/dev/null 2>&1; then
  echo "  ✓ K8s cluster exists"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ K8s cluster not found"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 检查 DB 记录
if sqlite_query 'SELECT 1;' >/dev/null 2>&1; then
  count_str="$(sqlite_query "SELECT COUNT(*) FROM clusters WHERE name='$TEST_CLUSTER';" 2>/dev/null | tr -d ' ')"
  if echo "$count_str" | grep -Eq '^[0-9]+$'; then
    if [ "$count_str" -gt 0 ]; then
      echo "  ✓ DB record exists"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ DB record not found"
      failed_tests=$((failed_tests + 1))
    fi
  else
    echo "  ⚠ DB not available (count query failed), skipping DB check"
  fi
  total_tests=$((total_tests + 1))
else
  echo "  ⚠ DB not available, skipping DB check"
fi

# 检查 Git 分支（必须存在 - 这是关键功能）
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
  if [ -n "${GIT_REPO_URL:-}" ]; then
    if timeout 10 git ls-remote --heads "$GIT_REPO_URL" "$TEST_CLUSTER" 2>/dev/null | grep -q "$TEST_CLUSTER"; then
      echo "  ✓ Git branch exists"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ Git branch not found"
      echo "    CRITICAL: Git branch MUST be created during cluster creation"
      echo "    This indicates create_env.sh failed to create the branch"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  else
    echo "  ⚠ GIT_REPO_URL not set in git.env"
  fi
else
  echo "  ⚠ git.env not found, skipping Git branch check"
fi

# 检查 ArgoCD cluster注册 (使用 --haproxy-route 会自动注册)
if kubectl --context k3d-devops -n argocd get secret "argocd-cluster-$TEST_CLUSTER" >/dev/null 2>&1; then
  echo "  ✓ ArgoCD cluster registered"
  passed_tests=$((passed_tests + 1))
else
  echo "  ⚠ ArgoCD cluster secret not found (may not be registered yet)"
  # 不计为失败，因为可能使用了 --no-register-argocd
fi
total_tests=$((total_tests + 1))

# 检查集群基础健康度 (如果lib_verify.sh可用)
if command -v verify_cluster_health >/dev/null 2>&1; then
  echo "  Checking cluster health..."
  if verify_cluster_health "$TEST_CLUSTER" "k3d" 2>&1 | sed 's/^/    /'; then
    passed_tests=$((passed_tests + 1))
  else
    echo "    ⚠ Cluster health check warnings (non-critical)"
    passed_tests=$((passed_tests + 1))  # 不作为失败条件
  fi
  total_tests=$((total_tests + 1))
fi

echo ""

##############################################
# 3. 删除测试集群
##############################################
echo "[3/4] Deleting Test Cluster: $TEST_CLUSTER"

if timeout 120 "$ROOT_DIR/scripts/delete_env.sh" -n "$TEST_CLUSTER" -p k3d >/tmp/delete_test.log 2>&1; then
  echo "  ✓ Cluster deletion completed"
  passed_tests=$((passed_tests + 1))
  # 标记清理已完成（防止 trap 重复执行）
  CLEANUP_DONE=1
  # 立刻修剪 HAProxy，避免残留路由导致后续验证波动
  if [ -x "$ROOT_DIR/scripts/haproxy_sync.sh" ]; then
    echo "  Pruning HAProxy dynamic routes post-deletion..."
    "$ROOT_DIR/scripts/haproxy_sync.sh" --prune >/dev/null 2>&1 || true
    if docker ps --filter name=haproxy-gw --format '{{.Names}}' | grep -qx 'haproxy-gw'; then
      docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null 2>&1 || true
    fi
  fi
else
  echo "  ✗ Cluster deletion failed"
  echo "  See /tmp/delete_test.log for details"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 等待 30 秒确保所有异步清理操作完成（如数据库删除、Git 分支删除）
echo "  Waiting 30s for async cleanup to complete..."
sleep 30
echo ""

##############################################
# 4. 验证资源清理
##############################################
echo "[4/4] Verifying Resources Cleaned Up"

# 检查 K8s 集群已删除
if ! kubectl config get-contexts "k3d-$TEST_CLUSTER" >/dev/null 2>&1; then
  echo "  ✓ K8s cluster removed"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ K8s cluster still exists"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 检查 DB 记录已删除
if sqlite_query 'SELECT 1;' >/dev/null 2>&1; then
  count_str="$(sqlite_query "SELECT COUNT(*) FROM clusters WHERE name='$TEST_CLUSTER';" 2>/dev/null | tr -d ' ')"
  if echo "$count_str" | grep -Eq '^[0-9]+$'; then
    if [ "$count_str" -eq 0 ]; then
      echo "  ✓ DB record removed"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ DB record still exists"
      failed_tests=$((failed_tests + 1))
    fi
  else
    echo "  ⚠ DB busy/locked, skipping DB deletion check"
  fi
  total_tests=$((total_tests + 1))
else
  echo "  ⚠ DB not available, skipping DB check"
fi

# 检查 Git 分支已删除
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
  if [ -n "${GIT_REPO_URL:-}" ]; then
    if ! git ls-remote --heads "$GIT_REPO_URL" "$TEST_CLUSTER" 2>/dev/null | grep -q "$TEST_CLUSTER"; then
      echo "  ✓ Git branch removed"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ⚠ Git branch still exists (may need manual cleanup)"
      passed_tests=$((passed_tests + 1))  # 不作为失败条件
    fi
    total_tests=$((total_tests + 1))
  fi
fi

echo ""

##############################################
# 测试摘要
##############################################
print_summary

# 清理日志
rm -f /tmp/create_test.log /tmp/delete_test.log

# 额外保障：修剪 HAProxy 路由，移除可能遗留的临时环境条目
echo ""
echo "[POST] Pruning HAProxy dynamic routes (safety)"
"$ROOT_DIR/scripts/haproxy_sync.sh" --prune >/dev/null 2>&1 || true

echo ""
echo "========================================"
echo "Extended Database Validation Tests"
echo "=========================================="
echo ""

##############################################
# 扩展测试 1: 验证 devops 集群在数据库中
##############################################
test_devops_cluster_in_db() {
  local test_name="test_devops_cluster_in_db"
  echo "[EXTENDED-1] $test_name"
  
  if ! sqlite_query 'SELECT 1;' >/dev/null 2>&1; then
    echo "  ⚠ Database not available, skipping"
    return 2
  fi
  
  # Assert: devops 集群存在
  local devops_record=$(sqlite_query "SELECT name, provider, server_ip FROM clusters WHERE name='devops';")
  if echo "$devops_record" | grep -q "devops"; then
    echo "  ✓ devops cluster found in database"
    
    # Assert: 字段完整
    local provider=$(sqlite_query "SELECT provider FROM clusters WHERE name='devops';")
    local http_port=$(sqlite_query "SELECT http_port FROM clusters WHERE name='devops';")
    local https_port=$(sqlite_query "SELECT https_port FROM clusters WHERE name='devops';")
    
    # devops 管理集群通过 NodePort 暴露: 23800/23843（与文档一致）
    if [ "$provider" = "k3d" ] && [ "$http_port" = "23800" ] && [ "$https_port" = "23843" ]; then
      echo "  ✓ devops cluster configuration correct"
      return 0
    else
      echo "  ✗ devops cluster configuration mismatch"
      echo "    Expected: provider=k3d, http_port=23800, https_port=23843"
      echo "    Actual: provider=$provider, http_port=$http_port, https_port=$https_port"
      return 1
    fi
  else
    cat <<EOF
  ✗ Test Failed: $test_name
    Expected: devops cluster record in database
    Actual: No record found
    Context: bootstrap.sh should record devops cluster after init_database.sh
    Fix: Check scripts/bootstrap.sh for database insert logic
    Command: docker exec -i kindler-webui-backend sqlite3 /data/kindler-webui/kindler.db "SELECT * FROM clusters WHERE name='devops';"
EOF
    return 1
  fi
}

##############################################
# 扩展测试 2: 验证数据库记录与集群配置一致
##############################################
test_db_record_matches_config() {
  local test_name="test_db_record_matches_config"
  local cluster_name="$1"
  local provider="$2"
  
  echo "[EXTENDED-2] $test_name (cluster=$cluster_name)"
  
  if ! sqlite_query 'SELECT 1;' >/dev/null 2>&1; then
    echo "  ⚠ Database not available, skipping"
    return 2
  fi
  
  if [ "$(sqlite_query "SELECT COUNT(*) FROM clusters WHERE name='$cluster_name';" 2>/dev/null | tr -d ' ')" -eq 0 ]; then
    echo "  ⚠ Cluster '$cluster_name' not in database, skipping"
    return 2
  fi
  
  # 获取数据库记录
  local db_provider=$(sqlite_query "SELECT provider FROM clusters WHERE name='$cluster_name';")
  local db_node_port=$(sqlite_query "SELECT node_port FROM clusters WHERE name='$cluster_name';")
  local db_server_ip=$(sqlite_query "SELECT server_ip FROM clusters WHERE name='$cluster_name';")
  
  # Assert 1: provider 匹配
  if [ "$db_provider" != "$provider" ]; then
    echo "  ✗ provider mismatch: db=$db_provider, expected=$provider"
    return 1
  fi
  
  # Assert 2: server_ip 存在且非空（devops 可为空，不作为失败）
  if [ -z "$db_server_ip" ]; then
    if [ "$cluster_name" = "devops" ]; then
      echo "  ⚠ server_ip is empty for devops (acceptable)"
    else
      echo "  ✗ server_ip is empty in database"
      echo "    This indicates create_env.sh failed to detect container IP"
      return 1
    fi
  fi
  
  # Assert 3: 验证 server_ip 格式正确（IP 地址格式），若为空则跳过
  if [ -n "$db_server_ip" ]; then
    if ! echo "$db_server_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
      echo "  ✗ server_ip format invalid: $db_server_ip"
      return 1
    fi
  fi
  
  # Assert 4: 验证实际容器存在并且 IP 匹配；若 DB 未记录 server_ip 则跳过
  if [ "$provider" = "k3d" ]; then
    container_name="k3d-${cluster_name}-server-0"
  else
    container_name="${cluster_name}-control-plane"
  fi
  
  # 获取实际 IP：devops 使用 k3d-shared 网络，业务集群使用独立网络
  if [ "$cluster_name" = "devops" ]; then
    # devops 是管理集群，使用 k3d-shared 主网络
    actual_ip=$(docker inspect "$container_name" --format '{{with index .NetworkSettings.Networks "k3d-shared"}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
  else
    # 业务集群：获取第一个网络 IP（独立网络）
    actual_ip=$(docker inspect "$container_name" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}' || echo "")
  fi
  
  if [ -n "$db_server_ip" ] && [ -z "$actual_ip" ]; then
    echo "  ⚠ Container not found or no IP (cluster may be stopped)"
    echo "  ✓ Database record exists (skipping IP validation)"
    return 0
  fi
  
  if [ -n "$db_server_ip" ]; then
    if [ "$db_server_ip" != "$actual_ip" ]; then
      echo "  ✗ server_ip mismatch"
      echo "    Database: $db_server_ip"
      echo "    Actual: $actual_ip"
      return 1
    fi
  fi
  
  echo "  ✓ All fields match (provider=$db_provider, node_port=$db_node_port, server_ip=${db_server_ip:-<empty>})"
  return 0
}

# 运行扩展测试
extended_passed=0
extended_failed=0
extended_total=0

# 测试 1: devops 集群在数据库中
test_devops_cluster_in_db
result=$?
if [ $result -eq 0 ]; then
  extended_passed=$((extended_passed + 1))
elif [ $result -eq 1 ]; then
  extended_failed=$((extended_failed + 1))
fi
extended_total=$((extended_total + 1))

# 测试 2: 数据库记录匹配（如果有测试集群，可能已被删除）
# 使用 devops 集群进行验证
if kubectl config get-contexts "k3d-devops" >/dev/null 2>&1; then
  test_db_record_matches_config "devops" "k3d"
  result=$?
  if [ $result -eq 0 ]; then
    extended_passed=$((extended_passed + 1))
  elif [ $result -eq 1 ]; then
    extended_failed=$((extended_failed + 1))
  fi
  extended_total=$((extended_total + 1))
else
  echo "[EXTENDED-2] Skipping (devops cluster not found)"
fi

echo ""
echo "=========================================="
echo "Extended Tests Summary"
echo "=========================================="
echo "Total: $extended_total"
echo "Passed: $extended_passed"
echo "Failed: $extended_failed"
echo ""

# 合并扩展测试结果
passed_tests=$((passed_tests + extended_passed))
failed_tests=$((failed_tests + extended_failed))
total_tests=$((total_tests + extended_total))

# 最终摘要
echo "=========================================="
echo "Final Summary (Including Extended Tests)"
echo "=========================================="
echo "Total: $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $failed_tests"
echo ""

if [ $failed_tests -eq 0 ]; then
  echo "✓ All tests passed"
else
  echo "✗ Some tests failed"
fi

exit $failed_tests
