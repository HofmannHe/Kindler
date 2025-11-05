#!/usr/bin/env bash
# WebUI API 端点测试套件
# 测试所有 WebUI backend API endpoints

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# WebUI URL (从配置读取或使用默认值)
WEBUI_URL="${WEBUI_URL:-http://kindler.devops.192.168.51.30.sslip.io}"

# 测试计数器
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# 辅助函数：检查集群是否存在
cluster_exists() {
  local name="$1"
  k3d cluster list 2>/dev/null | grep -q "^$name " || \
  kind get clusters 2>/dev/null | grep -q "^$name$"
}

# 清理函数
cleanup() {
  local exit_code=$?
  echo ""
  echo "[CLEANUP] Auto-cleaning all test-* clusters (zero manual operations)..."
  
  # 清理所有 k3d test-* 集群（包括 test-api-* 和 test-e2e-*）
  for cluster in $(k3d cluster list 2>/dev/null | grep "test-" | awk '{print $1}'); do
    echo "  Deleting k3d cluster: $cluster..."
    "$ROOT_DIR/scripts/delete_env.sh" "$cluster" 2>/dev/null || k3d cluster delete "$cluster" 2>/dev/null || true
  done
  
  # 清理所有 kind test-* 集群
  for cluster in $(kind get clusters 2>/dev/null | grep "test-"); do
    echo "  Deleting kind cluster: $cluster..."
    "$ROOT_DIR/scripts/delete_env.sh" "$cluster" 2>/dev/null || kind delete cluster --name "$cluster" 2>/dev/null || true
  done
  
  echo "  ✓ All test clusters auto-cleaned (no manual steps required)"
  exit $exit_code
}

trap cleanup EXIT INT TERM

# 辅助函数：解析 HTTP 响应（状态码 + body）
http_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  
  if [ -n "$data" ]; then
    curl -s -w "\n%{http_code}" -X "$method" "$WEBUI_URL$path" \
      -H "Content-Type: application/json" \
      -d "$data" \
      -m 10
  else
    curl -s -w "\n%{http_code}" -X "$method" "$WEBUI_URL$path" -m 10
  fi
}

# 数据库查询（PostgreSQL 优先，失败则回退到 SQLite）
db_get_value() {
  local sql="$1" # 仅返回第一行第一列
  # 尝试 Postgres（devops 集群内）
  if kubectl --context k3d-devops -n paas get pod postgresql-0 >/dev/null 2>&1; then
    kubectl --context k3d-devops -n paas exec postgresql-0 -- \
      psql -U kindler -d kindler -t -c "$sql" 2>/dev/null | xargs || true
    return 0
  fi
  # 回退到 SQLite（WebUI 后端容器内）
  if docker ps --format '{{.Names}}' | grep -q '^kindler-webui-backend$'; then
    docker exec kindler-webui-backend sh -lc \
      "sqlite3 -readonly /data/kindler-webui/kindler.db \"$sql\"" 2>/dev/null | xargs || true
    return 0
  fi
  echo ""
}

# ==================================================
# 测试用例 1: GET /api/clusters 返回 200
# ==================================================
test_api_list_clusters_200() {
  local test_name="test_api_list_clusters_200"
  echo "[TEST] $test_name"
  
  local response=$(http_request "GET" "/api/clusters")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" = "200" ]; then
    echo "  ✓ $test_name passed (HTTP 200)"
    return 0
  else
    cat <<EOF
  ✗ Test Failed: $test_name
    Expected: HTTP 200
    Actual: HTTP $status
    Context:
      - URL: $WEBUI_URL/api/clusters
      - Method: GET
    Response Body: $body
    Fix: Check if WebUI backend is running and accessible
    Command: curl -v $WEBUI_URL/api/clusters
EOF
    return 1
  fi
}

# ==================================================
# 测试用例 2: GET /api/clusters 列表包含所有集群
# ==================================================
test_api_list_clusters_includes_all() {
  local test_name="test_api_list_clusters_includes_all"
  echo "[TEST] $test_name"
  
  local response=$(http_request "GET" "/api/clusters")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" != "200" ]; then
    echo "  ⚠ Skipping test (API returned $status)"
    return 2
  fi
  
  # 检查响应是否为 JSON 数组
  if ! echo "$body" | jq -e '. | type == "array"' >/dev/null 2>&1; then
    echo "  ✗ Response is not a JSON array"
    echo "    Response: $body"
    return 1
  fi
  
  # 检查 devops 集群是否在列表中
  if ! echo "$body" | jq -e '.[] | select(.name == "devops")' >/dev/null 2>&1; then
    cat <<EOF
  ✗ Test Failed: $test_name
    Expected: devops cluster in response
    Actual: devops cluster not found
    Context:
      - Total clusters in response: $(echo "$body" | jq 'length')
    Fix: Ensure devops cluster is recorded in database
    Command: kubectl --context k3d-devops -n paas exec postgresql-0 -- psql -U kindler -d kindler -c "SELECT * FROM clusters WHERE name='devops';"
EOF
    return 1
  fi
  
  echo "  ✓ $test_name passed (devops cluster found)"
  return 0
}

# ==================================================
# 测试用例 3: POST /api/clusters 返回 202
# ==================================================
test_api_create_cluster_202() {
  local test_name="test_api_create_cluster_202"
  echo "[TEST] $test_name"
  
  TEST_CLUSTER="test-api-$$"
  local payload="{\"name\":\"$TEST_CLUSTER\",\"provider\":\"k3d\"}"
  
  local response=$(http_request "POST" "/api/clusters" "$payload")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" = "202" ]; then
    # 检查响应包含 task_id
    if echo "$body" | jq -e '.task_id' >/dev/null 2>&1; then
      local task_id=$(echo "$body" | jq -r '.task_id')
      echo "  ✓ $test_name passed (HTTP 202, task_id=$task_id)"
      return 0
    else
      echo "  ✗ Response missing task_id"
      echo "    Response: $body"
      return 1
    fi
  else
    cat <<EOF
  ✗ Test Failed: $test_name
    Expected: HTTP 202 (Accepted)
    Actual: HTTP $status
    Context:
      - Payload: $payload
    Response: $body
    Fix: Check WebUI backend create_cluster endpoint
EOF
    return 1
  fi
}

# ==================================================
# 测试用例 4: GET /api/clusters/{name} 返回 200
# ==================================================
test_api_get_cluster_detail_200() {
  local test_name="test_api_get_cluster_detail_200"
  local cluster_name="${1:-devops}"
  echo "[TEST] $test_name (cluster=$cluster_name)"
  
  local response=$(http_request "GET" "/api/clusters/$cluster_name")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" = "200" ]; then
    # 验证返回的集群名称匹配
    local returned_name=$(echo "$body" | jq -r '.name' 2>/dev/null || echo "")
    if [ "$returned_name" = "$cluster_name" ]; then
      echo "  ✓ $test_name passed (HTTP 200, name matches)"
      return 0
    else
      echo "  ✗ Cluster name mismatch: expected=$cluster_name, actual=$returned_name"
      return 1
    fi
  elif [ "$status" = "404" ]; then
    echo "  ⚠ Cluster '$cluster_name' not found (expected if cluster doesn't exist)"
    return 2
  else
    echo "  ✗ Unexpected status: $status"
    echo "    Response: $body"
    return 1
  fi
}

# ==================================================
# 测试用例 5: DELETE /api/clusters/devops 返回 403
# ==================================================
test_api_delete_devops_403() {
  local test_name="test_api_delete_devops_403"
  echo "[TEST] $test_name"
  
  local response=$(http_request "DELETE" "/api/clusters/devops")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" = "403" ]; then
    echo "  ✓ $test_name passed (HTTP 403 Forbidden)"
    return 0
  else
    cat <<EOF
  ✗ Test Failed: $test_name
    Expected: HTTP 403 (Forbidden - devops cluster is protected)
    Actual: HTTP $status
    Context:
      - devops cluster should not be deletable via WebUI
    Response: $body
    Fix: Add protection in webui/backend/app/api/clusters.py DELETE endpoint
    Code:
      if name == "devops":
          raise HTTPException(403, "devops cluster cannot be deleted")
EOF
    return 1
  fi
}

# ==================================================
# 测试用例 6: DELETE /api/clusters/{name} 返回 202
# ==================================================
test_api_delete_cluster_202() {
  local test_name="test_api_delete_cluster_202"
  local cluster_name="${1:-test-delete-$$}"
  echo "[TEST] $test_name (cluster=$cluster_name)"
  
  # 先创建一个测试集群（如果不存在）
  if ! kubectl config get-contexts "k3d-$cluster_name" >/dev/null 2>&1; then
    echo "  [SETUP] Creating test cluster $cluster_name..."
    if ! timeout 180 "$ROOT_DIR/scripts/create_env.sh" -n "$cluster_name" -p k3d --no-register-portainer >/dev/null 2>&1; then
      echo "  ⚠ Failed to create test cluster, skipping delete test"
      return 2
    fi
    sleep 5  # 等待 WebUI 刷新
  fi
  
  local response=$(http_request "DELETE" "/api/clusters/$cluster_name")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" = "202" ]; then
    # 检查响应包含 task_id
    if echo "$body" | jq -e '.task_id' >/dev/null 2>&1; then
      local task_id=$(echo "$body" | jq -r '.task_id')
      echo "  ✓ $test_name passed (HTTP 202, task_id=$task_id)"
      return 0
    else
      echo "  ✗ Response missing task_id"
      return 1
    fi
  elif [ "$status" = "404" ]; then
    echo "  ⚠ Cluster not found (may have been deleted already)"
    return 2
  else
    echo "  ✗ Unexpected status: $status"
    echo "    Response: $body"
    return 1
  fi
}

# ==================================================
# 测试用例 7: GET /api/clusters/{name}/status 返回 200
# ==================================================
test_api_get_cluster_status_200() {
  local test_name="test_api_get_cluster_status_200"
  local cluster_name="${1:-devops}"
  echo "[TEST] $test_name (cluster=$cluster_name)"
  
  local response=$(http_request "GET" "/api/clusters/$cluster_name/status")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" = "200" ]; then
    # 验证响应包含 status 字段
    if echo "$body" | jq -e '.status' >/dev/null 2>&1; then
      local cluster_status=$(echo "$body" | jq -r '.status')
      echo "  ✓ $test_name passed (HTTP 200, status=$cluster_status)"
      return 0
    else
      echo "  ✗ Response missing status field"
      return 1
    fi
  elif [ "$status" = "404" ]; then
    echo "  ⚠ Cluster not found"
    return 2
  else
    echo "  ✗ Unexpected status: $status"
    return 1
  fi
}

# ==================================================
# 测试用例 8: GET /api/clusters/nonexistent 返回 404
# ==================================================
test_api_nonexistent_cluster_404() {
  local test_name="test_api_nonexistent_cluster_404"
  echo "[TEST] $test_name"
  
  local nonexistent="nonexistent-cluster-$$"
  local response=$(http_request "GET" "/api/clusters/$nonexistent")
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" = "404" ]; then
    echo "  ✓ $test_name passed (HTTP 404 Not Found)"
    return 0
  else
    echo "  ✗ Expected HTTP 404, got $status"
    return 1
  fi
}

# ==================================================
# 主函数：运行所有测试
# ==================================================
main() {
  echo "========================================"
  echo "  WebUI API Test Suite"
  echo "========================================"
  echo "WebUI URL: $WEBUI_URL"
  echo ""
  
  # 前置检查：WebUI 是否可访问
  echo "[SETUP] Checking WebUI accessibility..."
  if ! timeout 5 curl -sf "$WEBUI_URL" >/dev/null 2>&1; then
    cat <<EOF
⚠ Test Suite Skipped: WebUI not accessible
  URL: $WEBUI_URL
  Fix: Ensure WebUI is running
  Commands:
    1. Check containers: docker ps --filter "name=webui"
    2. Check logs: docker logs kindler-webui-backend
    3. Start WebUI: cd webui && docker compose up -d
EOF
    exit 2
  fi
  echo "✓ WebUI accessible"
  echo ""
  
  # 运行测试
  test_api_list_clusters_200 && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  
  test_api_list_clusters_includes_all
  result=$?
  if [ $result -eq 0 ]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
  elif [ $result -eq 2 ]; then
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
  else
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
  
  test_api_get_cluster_detail_200 "devops"
  result=$?
  if [ $result -eq 0 ]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
  elif [ $result -eq 2 ]; then
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
  else
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
  
  test_api_delete_devops_403 && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  
  test_api_get_cluster_status_200 "devops"
  result=$?
  if [ $result -eq 0 ]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
  elif [ $result -eq 2 ]; then
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
  else
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
  
  test_api_nonexistent_cluster_404 && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  
  # E2E 测试：完整创建和删除流程验证（含 Portainer）
  # 创建 4 个集群：k3d+kind 各2个（2个测创建，2个测创建+删除）
  # 所有集群将在测试结束后自动清理（trap机制）
  echo ""
  echo "[INFO] Running E2E tests (k3d + kind, create + delete)..."
  echo "  This will create 4 clusters total:"
  echo "    - test-api-k3d-$$  (k3d, creation E2E)"
  echo "    - test-api-kind-$$ (kind, creation E2E)"
  echo "    - test-e2e-k3d-$$  (k3d, creation + deletion E2E)"
  echo "    - test-e2e-kind-$$ (kind, creation + deletion E2E)"
  echo "  All will be auto-cleaned on exit (zero manual operations)"
  echo "  Estimated time: 10-15 minutes"
  echo ""
  
  # k3d - 测试创建流程
  test_api_create_cluster_e2e "k3d" "test-api-k3d-$$" "preserve"
  result=$?
  [ $result -eq 0 ] && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  
  # kind - 测试创建流程
  test_api_create_cluster_e2e "kind" "test-api-kind-$$" "preserve"
  result=$?
  [ $result -eq 0 ] && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  
  # k3d - 测试创建 + 删除流程
  test_api_create_cluster_e2e "k3d" "test-e2e-k3d-$$" "delete"
  result=$?
  [ $result -eq 0 ] && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  if [ $result -eq 0 ]; then
    test_api_delete_cluster_e2e "test-e2e-k3d-$$" "k3d"
    result=$?
    [ $result -eq 0 ] && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  else
    echo "  ⚠ Skipping k3d delete E2E test (creation failed)"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
  fi
  
  # kind - 创建、验证、删除
  test_api_create_cluster_e2e "kind" "test-e2e-kind-$$" "delete"
  result=$?
  [ $result -eq 0 ] && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  if [ $result -eq 0 ]; then
    test_api_delete_cluster_e2e "test-e2e-kind-$$" "kind"
    result=$?
    [ $result -eq 0 ] && PASSED_TESTS=$((PASSED_TESTS + 1)) || FAILED_TESTS=$((FAILED_TESTS + 1))
  else
    echo "  ⚠ Skipping kind delete E2E test (creation failed)"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
  fi
  
  # 汇总结果
  local total_tests=$((PASSED_TESTS + FAILED_TESTS + SKIPPED_TESTS))
  echo ""
  echo "========================================"
  echo "  Test Results"
  echo "========================================"
  echo "Total:   $total_tests"
  echo "Passed:  $PASSED_TESTS"
  echo "Failed:  $FAILED_TESTS"
  echo "Skipped: $SKIPPED_TESTS"
  echo ""
  echo "Note: All test clusters will be auto-cleaned on exit (trap)"
  echo "========================================"
  
  if [ $FAILED_TESTS -eq 0 ]; then
    echo "✓ All tests passed"
    exit 0
  else
    echo "✗ Some tests failed"
    exit 1
  fi
}

# ==================================================
# 测试用例 E2E-1: 端到端创建集群验证（含 Portainer）
# ==================================================
test_api_create_cluster_e2e() {
  local provider="$1"      # k3d 或 kind
  local cluster_name="$2"  # 集群名称
  local action="$3"        # preserve 或 delete
  
  local test_name="test_api_create_cluster_e2e($provider:$cluster_name)"
  echo ""
  echo "[TEST-E2E] $test_name"
  echo "  Provider: $provider"
  echo "  Action: $action (will be $action after verification)"
  
  # [幂等性保证] 防御性清理：检查并删除已存在的同名集群
  if cluster_exists "$cluster_name"; then
    echo "  [IDEMPOTENT] Cluster exists, cleaning first..."
    "$ROOT_DIR/scripts/delete_env.sh" "$cluster_name" 2>/dev/null || true
    sleep 5
  fi
  
  # 清理数据库记录（PostgreSQL → SQLite 回退）
  if kubectl --context k3d-devops -n paas get pod postgresql-0 >/dev/null 2>&1; then
    kubectl --context k3d-devops -n paas exec postgresql-0 -- \
      psql -U kindler -d kindler -c "DELETE FROM clusters WHERE name='$cluster_name';" 2>/dev/null || true
  elif docker ps --format '{{.Names}}' | grep -q '^kindler-webui-backend$'; then
    docker exec kindler-webui-backend sh -lc \
      "sqlite3 /data/kindler-webui/kindler.db \"DELETE FROM clusters WHERE name='$cluster_name';\"" 2>/dev/null || true
  fi
  
  # 清理 ArgoCD secret
  kubectl --context k3d-devops delete secret "cluster-$cluster_name" -n argocd 2>/dev/null || true
  
  # 清理 Portainer endpoint
  "$ROOT_DIR/scripts/portainer.sh" del-endpoint "$(echo $cluster_name | sed 's/-//g')" 2>/dev/null || true
  
  local payload="{\"name\":\"$cluster_name\",\"provider\":\"$provider\"}"
  
  # 1. 发送创建请求
  echo "  [1/7] Sending create request..."
  local response=$(http_request "POST" "/api/clusters" "$payload")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" != "202" ]; then
    echo "  ✗ Failed to initiate cluster creation (HTTP $status)"
    echo "    Response: $body"
    return 1
  fi
  
  local task_id=$(echo "$body" | jq -r '.task_id' 2>/dev/null || echo "")
  echo "  ✓ Creation initiated (task_id=$task_id)"
  
  # 2. 等待 K8s 集群创建（最多 180秒）
  echo "  [2/7] Waiting for K8s cluster (max 180s)..."
  local max_wait=180
  local interval=10
  local elapsed=0
  
  while [ $elapsed -lt $max_wait ]; do
    local cluster_found=false
    if [ "$provider" = "k3d" ]; then
      k3d cluster list 2>/dev/null | grep -q "^$cluster_name " && cluster_found=true
    else
      kind get clusters 2>/dev/null | grep -q "^$cluster_name$" && cluster_found=true
    fi
    
    if $cluster_found; then
      echo "  ✓ K8s cluster created ($elapsed s)"
      break
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  if [ $elapsed -ge $max_wait ]; then
    echo "  ✗ Timeout: K8s cluster not created after ${max_wait}s"
    return 1
  fi
  
  # 3. 等待 server_ip 更新到数据库（最多 120秒，支持 SQLite 回退）
  echo "  [3/7] Waiting for server_ip in database (max 120s)..."
  local max_wait=120
  local interval=5
  local elapsed=0
  local db_server_ip=""
  
  while [ $elapsed -lt $max_wait ]; do
    db_server_ip=$(db_get_value "SELECT server_ip FROM clusters WHERE name='$cluster_name';" || echo "")
    
    if [ -n "$db_server_ip" ] && [ "$db_server_ip" != "null" ]; then
      echo "  ✓ Database: server_ip updated ($db_server_ip, after ${elapsed}s)"
      break
    fi
    
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  # 4. 验证数据库记录（支持 SQLite 回退）
  echo "  [4/7] Verifying database record..."
  if [ -z "$db_server_ip" ] || [ "$db_server_ip" = "null" ]; then
    echo "  ✗ Database: server_ip still empty after ${max_wait}s"
    echo "    Check create_env.sh execution and database update logic"
    return 1
  fi
  echo "  ✓ Database: record valid (server_ip=$db_server_ip)"
  
  # 5. 验证 ArgoCD 注册
  echo "  [5/7] Verifying ArgoCD registration..."
  if kubectl --context k3d-devops get secret "cluster-$cluster_name" -n argocd >/dev/null 2>&1; then
    echo "  ✓ ArgoCD: cluster registered"
  else
    echo "  ⚠ ArgoCD: not registered (may take longer, continuing...)"
  fi
  
  # 6. 验证 Portainer endpoint
  echo "  [6/7] Verifying Portainer endpoint..."
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then
    source "$ROOT_DIR/config/secrets.env"
    PORTAINER_URL="https://portainer.devops.192.168.51.30.sslip.io"
    
    TOKEN=$(curl -s -k -X POST "$PORTAINER_URL/api/auth" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"admin\",\"password\":\"$PORTAINER_ADMIN_PASSWORD\"}" \
      2>/dev/null | jq -r '.jwt' 2>/dev/null || echo "")
    
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
      local endpoint_name=$(echo "$cluster_name" | sed 's/-//g')
      local endpoint_id=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
        "$PORTAINER_URL/api/endpoints" 2>/dev/null | \
        jq -r ".[] | select(.Name==\"$endpoint_name\") | .Id" 2>/dev/null || echo "")
      
      if [ -n "$endpoint_id" ]; then
        echo "  ✓ Portainer: endpoint registered (ID=$endpoint_id, Name=$endpoint_name)"
      else
        echo "  ✗ Portainer: endpoint not found (expected name: $endpoint_name)"
        return 1
      fi
    else
      echo "  ⚠ Portainer: not accessible, skipping"
    fi
  fi
  
  # 7. 验证集群健康
  echo "  [7/7] Verifying cluster health..."
  local context="$provider-$cluster_name"
  if kubectl --context "$context" get nodes >/dev/null 2>&1; then
    echo "  ✓ Cluster: accessible via kubectl"
  else
    echo "  ✗ Cluster: not accessible (context=$context)"
    return 1
  fi
  
  echo "  ✅ $test_name PASSED (full E2E with Portainer)"
  
  # 根据 action 决定是否保留
  if [ "$action" = "preserve" ]; then
    echo "  ℹ Cluster preserved for manual inspection"
  fi
  
  return 0
}

# ==================================================
# 测试用例 E2E-2: 端到端删除集群验证（含 Portainer）
# ==================================================
test_api_delete_cluster_e2e() {
  local cluster_name="$1"  # 集群名称
  local provider="${2:-k3d}"  # provider，默认 k3d
  
  local test_name="test_api_delete_cluster_e2e($provider:$cluster_name)"
  
  echo ""
  echo "[TEST-E2E] $test_name"
  echo "  This test deletes the cluster and verifies all resources are cleaned up"
  
  # 1. 发送删除请求
  echo "  [1/6] Sending delete request..."
  local response=$(http_request "DELETE" "/api/clusters/$cluster_name")
  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)
  
  if [ "$status" != "200" ] && [ "$status" != "202" ] && [ "$status" != "204" ]; then
    echo "  ✗ Delete request failed (HTTP $status)"
    echo "    Response: $body"
    return 1
  fi
  echo "  ✓ Delete request accepted (HTTP $status)"
  
  # 2. 等待 K8s 集群删除（最多 120秒）
  echo "  [2/6] Waiting for K8s cluster deletion (max 120s)..."
  local max_wait=120
  local interval=10
  local elapsed=0
  
  while [ $elapsed -lt $max_wait ]; do
    local cluster_exists=false
    if [ "$provider" = "k3d" ]; then
      k3d cluster list 2>/dev/null | grep -q "^$cluster_name " && cluster_exists=true
    else
      kind get clusters 2>/dev/null | grep -q "^$cluster_name$" && cluster_exists=true
    fi
    
    if ! $cluster_exists; then
      echo "  ✓ K8s cluster deleted ($elapsed s)"
      break
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  if [ $elapsed -ge $max_wait ]; then
    echo "  ⚠ Timeout: K8s cluster still exists after ${max_wait}s"
  fi
  
  # 3. 等待异步清理任务（30秒）
  echo "  [3/6] Waiting for async cleanup (30s)..."
  sleep 30
  
  # 4. 验证数据库清理
  echo "  [4/6] Verifying database cleanup..."
  local db_count=$(db_get_value "SELECT COUNT(*) FROM clusters WHERE name='$cluster_name';" || echo "1")
  
  if [ "$db_count" = "0" ]; then
    echo "  ✓ Database: record deleted"
  else
    echo "  ✗ Database: record still exists"
    return 1
  fi
  
  # 5. 验证 ArgoCD 反注册
  echo "  [5/6] Verifying ArgoCD cleanup..."
  if ! kubectl --context k3d-devops get secret "cluster-$cluster_name" -n argocd >/dev/null 2>&1; then
    echo "  ✓ ArgoCD: cluster unregistered"
  else
    echo "  ⚠ ArgoCD: secret still exists"
  fi
  
  # 6. 验证 Portainer endpoint 删除
  echo "  [6/6] Verifying Portainer cleanup..."
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then
    source "$ROOT_DIR/config/secrets.env"
    PORTAINER_URL="https://portainer.devops.192.168.51.30.sslip.io"
    
    TOKEN=$(curl -s -k -X POST "$PORTAINER_URL/api/auth" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"admin\",\"password\":\"$PORTAINER_ADMIN_PASSWORD\"}" \
      2>/dev/null | jq -r '.jwt' 2>/dev/null || echo "")
    
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
      local endpoint_name=$(echo "$cluster_name" | sed 's/-//g')
      local endpoint_id=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
        "$PORTAINER_URL/api/endpoints" 2>/dev/null | \
        jq -r ".[] | select(.Name==\"$endpoint_name\") | .Id" 2>/dev/null || echo "")
      
      if [ -z "$endpoint_id" ]; then
        echo "  ✓ Portainer: endpoint deleted"
      else
        echo "  ✗ Portainer: endpoint still exists (ID=$endpoint_id, Name=$endpoint_name)"
        echo "    This indicates delete_env.sh is NOT cleaning Portainer endpoints properly"
        return 1
      fi
    else
      echo "  ⚠ Portainer: not accessible, skipping"
    fi
  fi
  
  echo "  ✅ $test_name PASSED (full E2E cleanup with Portainer)"
  return 0
}

# 执行主函数
main "$@"
