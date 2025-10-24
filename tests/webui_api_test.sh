#!/usr/bin/env bash
# WebUI API 端点测试套件
# 测试所有 WebUI backend API endpoints

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# WebUI URL (从配置读取或使用默认值)
WEBUI_URL="${WEBUI_URL:-http://kindler-webui.192.168.51.30.sslip.io}"

# 测试计数器
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# 清理函数
cleanup() {
  local exit_code=$?
  echo ""
  echo "[CLEANUP] Cleaning up test resources..."
  
  # 清理可能创建的测试集群
  if [ -n "${TEST_CLUSTER:-}" ]; then
    "$ROOT_DIR/scripts/delete_env.sh" "$TEST_CLUSTER" 2>/dev/null || true
  fi
  
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
  
  # 创建和删除测试（较重，可能失败）
  echo ""
  echo "[INFO] Running create/delete tests (may take a few minutes)..."
  test_api_create_cluster_202
  result=$?
  if [ $result -eq 0 ]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
  elif [ $result -eq 2 ]; then
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
  else
    FAILED_TESTS=$((FAILED_TESTS + 1))
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

