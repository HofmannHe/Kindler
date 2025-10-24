#!/usr/bin/env bash
#
# WebUI Comprehensive Test Suite
# 覆盖所有用户报告的问题，确保端到端功能正确
#
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
. "$ROOT_DIR/scripts/lib_db.sh"

# 测试配置
TEST_CLUSTER="test-webui-full"
TEST_PROVIDER="k3d"
API_URL="http://localhost:8001/api"
BASE_DOMAIN="${BASE_DOMAIN:-192.168.51.30.sslip.io}"

# 颜色输出
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[1;32m[✓]\033[0m $*"; }
fail() { echo -e "\033[1;31m[✗]\033[0m $*"; return 1; }
warn() { echo -e "\033[1;33m[⚠]\033[0m $*"; }

# 统计
total_tests=0
passed_tests=0
failed_tests=0

# 测试计数
test_count() {
  total_tests=$((total_tests + 1))
}

test_pass() {
  passed_tests=$((passed_tests + 1))
  success "$*"
}

test_fail() {
  failed_tests=$((failed_tests + 1))
  fail "$*" || true
}

# 获取Portainer API Token
get_portainer_token() {
  local portainer_url="https://portainer.devops.$BASE_DOMAIN"
  local username="admin"
  local password="${PORTAINER_ADMIN_PASSWORD}"
  
  if [ -z "$password" ]; then
    if [ -f "$ROOT_DIR/config/secrets.env" ]; then
      . "$ROOT_DIR/config/secrets.env"
      password="${PORTAINER_ADMIN_PASSWORD}"
    fi
  fi
  
  if [ -z "$password" ]; then
    fail "PORTAINER_ADMIN_PASSWORD not found in config/secrets.env"
    return 1
  fi
  
  info "Authenticating with Portainer..."
  local auth_response
  auth_response=$(curl -sk -X POST "$portainer_url/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$username\",\"password\":\"$password\"}" 2>/dev/null || echo '{}')
  
  local token
  token=$(echo "$auth_response" | jq -r '.jwt // empty')
  
  if [ -z "$token" ]; then
    fail "Failed to authenticate with Portainer"
    echo "Response: $auth_response"
    return 1
  fi
  
  PORTAINER_API_KEY="$token"
  export PORTAINER_API_KEY
  success "Portainer authentication successful"
  return 0
}

# 前置检查
check_prerequisites() {
  info "Checking prerequisites..."
  
  # 检查WebUI运行
  if ! curl -sf "$API_URL/clusters" >/dev/null 2>&1; then
    fail "WebUI API not accessible at $API_URL"
    return 1
  fi
  
  # 检查数据库
  if ! db_is_available 2>/dev/null; then
    fail "PostgreSQL database not available"
    return 1
  fi
  
  # 加载 secrets
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then
    . "$ROOT_DIR/config/secrets.env"
  fi
  
  # 获取Portainer API token
  if ! get_portainer_token; then
    return 1
  fi
  
  success "All prerequisites met"
  return 0
}

# 清理测试集群
cleanup_test_cluster() {
  local name="$1"
  info "Cleaning up test cluster: $name"
  
  # 删除k3d集群
  k3d cluster delete "$name" 2>/dev/null || true
  
  # 删除数据库记录
  if db_is_available 2>/dev/null; then
    kubectl --context k3d-devops exec -n paas postgresql-0 -- \
      psql -U kindler -d kindler -c "DELETE FROM clusters WHERE name='$name';" 2>/dev/null || true
  fi
  
  # 清理Git分支（如果存在）
  if [ -f "$ROOT_DIR/config/git.env" ]; then
    . "$ROOT_DIR/config/git.env"
    if [ -n "${GIT_REPO_URL:-}" ]; then
      local tmp_dir="/tmp/git-cleanup-$$"
      if timeout 30 git clone "$GIT_REPO_URL" "$tmp_dir" 2>/dev/null; then
        cd "$tmp_dir"
        if git show-ref --verify --quiet "refs/heads/$name"; then
          git push origin --delete "$name" 2>/dev/null || true
        fi
        cd - >/dev/null
        rm -rf "$tmp_dir"
      fi
    fi
  fi
  
  success "Cleanup completed for $name"
}

# 等待任务完成
wait_for_task() {
  local task_id="$1"
  local max_wait="${2:-300}" # 默认最多等5分钟
  local elapsed=0
  
  info "Waiting for task $task_id (max ${max_wait}s)..."
  
  while [ $elapsed -lt $max_wait ]; do
    local response
    response=$(curl -sf "$API_URL/tasks/$task_id" 2>/dev/null || echo '{"status":"unknown"}')
    local status
    status=$(echo "$response" | jq -r '.status')
    
    case "$status" in
      "completed")
        success "Task $task_id completed"
        return 0
        ;;
      "failed")
        fail "Task $task_id failed"
        echo "$response" | jq -r '.error_message // "Unknown error"'
        return 1
        ;;
      "pending"|"running")
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
        ;;
      *)
        fail "Task $task_id has unknown status: $status"
        return 1
        ;;
    esac
  done
  
  fail "Task $task_id timeout after ${max_wait}s"
  return 1
}

# 测试1: 任务持久化
test_task_persistence() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  Test 1: 任务持久化验证"
  info "═══════════════════════════════════════════════════════════════"
  
  # 创建集群
  test_count
  info "[1.1] Creating cluster to generate task..."
  local create_payload='{
    "name": "'"$TEST_CLUSTER"'",
    "provider": "'"$TEST_PROVIDER"'",
    "node_port": 30080,
    "pf_port": 19999,
    "http_port": 18999,
    "https_port": 18998,
    "cluster_subnet": null,
    "register_portainer": true,
    "haproxy_route": true,
    "register_argocd": true
  }'
  
  local response
  response=$(curl -sf -X POST "$API_URL/clusters" \
    -H "Content-Type: application/json" \
    -d "$create_payload" 2>/dev/null || echo '{"task_id":null}')
  
  local task_id
  task_id=$(echo "$response" | jq -r '.task_id')
  
  if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
    test_fail "Failed to create task"
    return 1
  fi
  
  test_pass "Task created: $task_id"
  
  # 等待任务完成
  test_count
  if wait_for_task "$task_id" 300; then
    test_pass "Task completed successfully"
  else
    test_fail "Task execution failed"
    return 1
  fi
  
  # 模拟页面刷新：重新获取任务状态
  test_count
  info "[1.2] Simulating page refresh (re-fetching task)..."
  sleep 2
  
  local task_detail
  task_detail=$(curl -sf "$API_URL/tasks/$task_id" 2>/dev/null || echo '{}')
  
  local task_status
  task_status=$(echo "$task_detail" | jq -r '.status')
  
  if [ "$task_status" = "completed" ]; then
    test_pass "Task status persisted after 'refresh' (status: $task_status)"
  else
    test_fail "Task status not persisted or incorrect (status: $task_status)"
    echo "Task detail: $task_detail"
  fi
  
  # 验证任务日志是否保存
  test_count
  local task_logs
  task_logs=$(echo "$task_detail" | jq -r '.logs // ""')
  
  if [ -n "$task_logs" ]; then
    test_pass "Task logs persisted (length: ${#task_logs} chars)"
  else
    test_fail "Task logs not persisted"
  fi
}

# 测试2: WebUI API可见性
test_webui_visibility() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  Test 2: WebUI API 可见性验证"
  info "═══════════════════════════════════════════════════════════════"
  
  # 获取集群列表
  test_count
  info "[2.1] Fetching cluster list from WebUI API..."
  local clusters_json
  clusters_json=$(curl -sf "$API_URL/clusters" 2>/dev/null || echo '[]')
  
  local cluster_names
  cluster_names=$(echo "$clusters_json" | jq -r '.[].name' | sort)
  
  if echo "$cluster_names" | grep -q "^$TEST_CLUSTER$"; then
    test_pass "Test cluster visible in WebUI API"
  else
    test_fail "Test cluster NOT visible in WebUI API"
    echo "Expected: $TEST_CLUSTER"
    echo "Got: $cluster_names"
  fi
  
  # 验证DB中有记录
  test_count
  info "[2.2] Verifying DB record..."
  local db_cluster
  db_cluster=$(db_get_cluster "$TEST_CLUSTER" 2>/dev/null || echo '{}')
  
  if [ "$db_cluster" != "{}" ] && [ "$db_cluster" != "null" ]; then
    test_pass "Cluster exists in database"
  else
    test_fail "Cluster NOT in database"
  fi
  
  # 验证k3d集群存在
  test_count
  info "[2.3] Verifying k3d cluster exists..."
  if k3d cluster list 2>/dev/null | grep -q "$TEST_CLUSTER"; then
    test_pass "k3d cluster exists"
  else
    test_fail "k3d cluster does NOT exist"
  fi
}

# 测试3: Portainer集成
test_portainer_integration() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  Test 3: Portainer 集成验证"
  info "═══════════════════════════════════════════════════════════════"
  
  # 获取Portainer endpoints
  test_count
  info "[3.1] Fetching Portainer endpoints..."
  
  # 重新获取token以防过期
  if ! get_portainer_token; then
    test_fail "Failed to refresh Portainer token"
    return 1
  fi
  
  local portainer_url="https://portainer.devops.$BASE_DOMAIN"
  local endpoints_json
  endpoints_json=$(curl -sk "$portainer_url/api/endpoints" \
    -H "X-API-Key: $PORTAINER_API_KEY" 2>/dev/null || echo '[]')
  
  if [ "$endpoints_json" = "[]" ]; then
    test_fail "Failed to fetch Portainer endpoints (check API key)"
    return 1
  fi
  
  local endpoint_count
  endpoint_count=$(echo "$endpoints_json" | jq '. | length')
  test_pass "Portainer returned $endpoint_count endpoint(s)"
  
  # 验证测试集群的endpoint
  test_count
  info "[3.2] Verifying test cluster endpoint..."
  local test_endpoint
  test_endpoint=$(echo "$endpoints_json" | jq -c ".[] | select(.Name==\"$TEST_CLUSTER\")")
  
  if [ -n "$test_endpoint" ]; then
    test_pass "Test cluster endpoint exists in Portainer"
    
    # 检查状态
    test_count
    local endpoint_status
    endpoint_status=$(echo "$test_endpoint" | jq -r '.Status')
    
    # EdgeAgent 需要时间连接，给予3分钟等待时间
    if [ "$endpoint_status" != "1" ]; then
      info "EdgeAgent not yet online, waiting up to 3 minutes..."
      local wait_count=0
      while [ $wait_count -lt 36 ]; do
        sleep 5
        endpoints_json=$(curl -sk "$portainer_url/api/endpoints" \
          -H "X-API-Key: $PORTAINER_API_KEY" 2>/dev/null || echo '[]')
        test_endpoint=$(echo "$endpoints_json" | jq -c ".[] | select(.Name==\"$TEST_CLUSTER\")")
        endpoint_status=$(echo "$test_endpoint" | jq -r '.Status')
        
        if [ "$endpoint_status" = "1" ]; then
          break
        fi
        echo -n "."
        wait_count=$((wait_count + 1))
      done
      echo ""
    fi
    
    if [ "$endpoint_status" = "1" ]; then
      test_pass "Endpoint status is online (Status: $endpoint_status)"
    else
      test_fail "Endpoint status is NOT online (Status: $endpoint_status, expected: 1)"
    fi
  else
    test_fail "Test cluster endpoint NOT found in Portainer"
  fi
  
  # 对比：DB中的集群 vs Portainer endpoints
  test_count
  info "[3.3] Comparing DB clusters with Portainer endpoints..."
  local db_clusters
  db_clusters=$(kubectl --context k3d-devops exec -n paas postgresql-0 -- \
    psql -U kindler -d kindler -t -c "SELECT name FROM clusters WHERE provider IN ('k3d', 'kind') AND name != 'devops' ORDER BY name;" 2>/dev/null | tr -d ' ')
  
  local portainer_names
  portainer_names=$(echo "$endpoints_json" | jq -r '.[].Name' | sort)
  
  local missing_in_portainer=0
  for cluster in $db_clusters; do
    if ! echo "$portainer_names" | grep -q "^$cluster$"; then
      warn "Cluster in DB but NOT in Portainer: $cluster"
      missing_in_portainer=$((missing_in_portainer + 1))
    fi
  done
  
  if [ $missing_in_portainer -eq 0 ]; then
    test_pass "All DB clusters exist in Portainer"
  else
    test_fail "$missing_in_portainer cluster(s) in DB but NOT in Portainer"
  fi
}

# 测试4: ArgoCD集成
test_argocd_integration() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  Test 4: ArgoCD 集成验证"
  info "═══════════════════════════════════════════════════════════════"
  
  # 验证cluster secret存在
  test_count
  info "[4.1] Verifying ArgoCD cluster secret..."
  local cluster_secret_name="cluster-$TEST_CLUSTER"
  
  if kubectl --context k3d-devops -n argocd get secret "$cluster_secret_name" >/dev/null 2>&1; then
    test_pass "ArgoCD cluster secret exists: $cluster_secret_name"
  else
    test_fail "ArgoCD cluster secret NOT found: $cluster_secret_name"
    kubectl --context k3d-devops -n argocd get secret -l argocd.argoproj.io/secret-type=cluster -o name
    return 1
  fi
  
  # 验证Application是否生成
  test_count
  info "[4.2] Verifying ArgoCD Application..."
  local app_name="whoami-$TEST_CLUSTER"
  
  # ApplicationSet 需要时间同步，最多等待2分钟
  local app_found=false
  local wait_count=0
  while [ $wait_count -lt 24 ]; do
    if kubectl --context k3d-devops -n argocd get application "$app_name" >/dev/null 2>&1; then
      app_found=true
      break
    fi
    echo -n "."
    sleep 5
    wait_count=$((wait_count + 1))
  done
  echo ""
  
  if [ "$app_found" = true ]; then
    test_pass "ArgoCD Application exists: $app_name"
  else
    test_fail "ArgoCD Application NOT found: $app_name"
    kubectl --context k3d-devops -n argocd get application -o name | head -10
  fi
  
  # 验证Application sync状态（最多等待5分钟）
  if [ "$app_found" = true ]; then
    test_count
    info "[4.3] Waiting for Application sync..."
    wait_count=0
    while [ $wait_count -lt 60 ]; do
      local sync_status
      sync_status=$(kubectl --context k3d-devops -n argocd get application "$app_name" \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
      
      if [ "$sync_status" = "Synced" ]; then
        test_pass "Application synced successfully"
        break
      fi
      
      echo -n "."
      sleep 5
      wait_count=$((wait_count + 1))
      
      if [ $wait_count -ge 60 ]; then
        test_fail "Application sync timeout (status: $sync_status)"
      fi
    done
    echo ""
  fi
}

# 测试5: 删除集群验证
test_cluster_deletion() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  Test 5: 集群删除验证"
  info "═══════════════════════════════════════════════════════════════"
  
  # 删除集群
  test_count
  info "[5.1] Deleting test cluster via WebUI API..."
  local delete_response
  delete_response=$(curl -sf -X DELETE "$API_URL/clusters/$TEST_CLUSTER" 2>/dev/null || echo '{"task_id":null}')
  
  local delete_task_id
  delete_task_id=$(echo "$delete_response" | jq -r '.task_id')
  
  if [ -z "$delete_task_id" ] || [ "$delete_task_id" = "null" ]; then
    test_fail "Failed to create delete task"
    return 1
  fi
  
  test_pass "Delete task created: $delete_task_id"
  
  # 等待删除完成
  test_count
  if wait_for_task "$delete_task_id" 300; then
    test_pass "Delete task completed"
  else
    test_fail "Delete task failed"
    return 1
  fi
  
  # 验证各处已清理
  
  # 验证DB
  test_count
  info "[5.2] Verifying DB cleanup..."
  local db_cluster
  db_cluster=$(db_get_cluster "$TEST_CLUSTER" 2>/dev/null || echo '')
  
  if [ -z "$db_cluster" ]; then
    test_pass "Cluster removed from database"
  else
    test_fail "Cluster still in database: $db_cluster"
  fi
  
  # 验证k3d
  test_count
  info "[5.3] Verifying k3d cleanup..."
  if ! k3d cluster list 2>/dev/null | grep -q "$TEST_CLUSTER"; then
    test_pass "k3d cluster deleted"
  else
    test_fail "k3d cluster still exists"
  fi
  
  # 验证Portainer
  test_count
  info "[5.4] Verifying Portainer cleanup..."
  sleep 5 # 给Portainer一点时间同步
  
  # 重新获取token以防过期
  if ! get_portainer_token; then
    warn "Failed to refresh Portainer token, skipping Portainer cleanup check"
    test_count # 标记这个测试被跳过
    return 0
  fi
  
  local portainer_url="https://portainer.devops.$BASE_DOMAIN"
  local endpoints_json
  endpoints_json=$(curl -sk "$portainer_url/api/endpoints" \
    -H "X-API-Key: $PORTAINER_API_KEY" 2>/dev/null || echo '[]')
  
  local test_endpoint
  test_endpoint=$(echo "$endpoints_json" | jq -c ".[] | select(.Name==\"$TEST_CLUSTER\")")
  
  if [ -z "$test_endpoint" ]; then
    test_pass "Portainer endpoint removed"
  else
    test_fail "Portainer endpoint still exists"
  fi
  
  # 验证ArgoCD
  test_count
  info "[5.5] Verifying ArgoCD cleanup..."
  local cluster_secret_name="cluster-$TEST_CLUSTER"
  
  if ! kubectl --context k3d-devops -n argocd get secret "$cluster_secret_name" >/dev/null 2>&1; then
    test_pass "ArgoCD cluster secret removed"
  else
    test_fail "ArgoCD cluster secret still exists"
  fi
}

# 主测试流程
main() {
  echo ""
  info "════════════════════════════════════════════════════════════════"
  info "  WebUI Comprehensive Test Suite"
  info "════════════════════════════════════════════════════════════════"
  echo ""
  
  # 前置检查
  if ! check_prerequisites; then
    echo ""
    fail "Prerequisites check failed, aborting tests"
    exit 1
  fi
  
  # 清理旧测试集群
  cleanup_test_cluster "$TEST_CLUSTER"
  
  # 运行测试
  test_task_persistence || true
  test_webui_visibility || true
  test_portainer_integration || true
  test_argocd_integration || true
  test_cluster_deletion || true
  
  # 输出统计
  echo ""
  info "════════════════════════════════════════════════════════════════"
  info "  Test Summary"
  info "════════════════════════════════════════════════════════════════"
  echo "  Total tests:  $total_tests"
  echo "  Passed:       $passed_tests"
  echo "  Failed:       $failed_tests"
  
  if [ $failed_tests -eq 0 ]; then
    echo ""
    success "All tests passed! ✓"
    exit 0
  else
    echo ""
    fail "$failed_tests test(s) failed"
    exit 1
  fi
}

main "$@"

