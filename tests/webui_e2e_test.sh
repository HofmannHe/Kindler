#!/usr/bin/env bash
# WebUI端到端测试 - 验证完整的创建/列表/删除流程

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

success() { echo -e "${GREEN}✓${NC} $*"; passed=$((passed + 1)); }
fail() { echo -e "${RED}✗${NC} $*"; failed=$((failed + 1)); }
info() { echo -e "${YELLOW}➜${NC} $*"; }

# API base URL
API_URL="http://localhost:8001/api"
WEBUI_CONTAINER="kindler-webui-backend"

# 检查WebUI是否运行
check_webui() {
  echo "[DEBUG] Checking container..." >&2
  echo "[DEBUG] WEBUI_CONTAINER=$WEBUI_CONTAINER" >&2
  echo "[DEBUG] Running: docker ps | grep $WEBUI_CONTAINER" >&2
  if docker ps | grep "$WEBUI_CONTAINER"; then
    echo "[DEBUG] Container found!" >&2
  else
    fail "WebUI backend not running"
    echo "[DEBUG] Docker ps output:" >&2
    docker ps >&2
    return 1
  fi
  echo "[DEBUG] Container OK, checking health..." >&2
  
  # 使用宿主机端口测试（避免docker exec可能的hang）
  if ! timeout 5 curl -sf http://localhost:8001/api/health > /dev/null 2>&1; then
    echo "[DEBUG] Health check failed!" >&2
    fail "WebUI health check failed"
    return 1
  fi
  echo "[DEBUG] Health OK" >&2
  success "WebUI backend is running"
  return 0
}

# 等待任务完成
wait_for_task() {
  local task_id=$1
  local max_wait=300  # 5分钟
  local elapsed=0
  
  while [ $elapsed -lt $max_wait ]; do
    local status=$(timeout 10 curl -s "http://localhost:8001/api/tasks/${task_id}" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unknown")
    
    if [ "$status" = "completed" ]; then
      return 0
    elif [ "$status" = "failed" ]; then
      info "Task failed, details:"
      timeout 10 curl -s "http://localhost:8001/api/tasks/${task_id}" 2>/dev/null | jq . || echo "{}"
      return 1
    fi
    
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  fail "Task timeout after ${max_wait}s"
  return 1
}

# 验证数据库记录
verify_db_record() {
  local name=$1
  local should_exist=$2  # "exists" or "not_exists"
  
  local count=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
    psql -U kindler -d kindler -t -c "SELECT COUNT(*) FROM clusters WHERE name='$name'" 2>/dev/null | xargs)
  
  if [ "$should_exist" = "exists" ]; then
    if [ "$count" = "1" ]; then
      success "DB record exists for $name"
    else
      fail "DB record not found for $name (count: $count)"
    fi
  else
    if [ "$count" = "0" ]; then
      success "DB record cleaned for $name"
    else
      fail "DB record still exists for $name (count: $count)"
    fi
  fi
}

# 验证K8s集群
verify_k8s_cluster() {
  local name=$1
  local provider=$2
  local should_exist=$3
  
  local exists=0
  case "$provider" in
    k3d)
      k3d cluster list 2>/dev/null | grep -q "^$name" && exists=1
      ;;
    kind)
      kind get clusters 2>/dev/null | grep -q "^$name$" && exists=1
      ;;
  esac
  
  if [ "$should_exist" = "exists" ]; then
    if [ $exists -eq 1 ]; then
      success "K8s cluster exists: $name ($provider)"
    else
      fail "K8s cluster not found: $name ($provider)"
    fi
  else
    if [ $exists -eq 0 ]; then
      success "K8s cluster cleaned: $name"
    else
      fail "K8s cluster still exists: $name"
    fi
  fi
}

# 验证Git分支
verify_git_branch() {
  local name=$1
  local should_exist=$2
  
  if [ ! -f "$ROOT_DIR/config/git.env" ]; then
    info "Skipping Git verification (git.env not found)"
    return
  fi
  
  source "$ROOT_DIR/config/git.env"
  
  local branch_exists=$(timeout 10 git ls-remote "$GIT_REPO_URL" "refs/heads/$name" 2>/dev/null | wc -l)
  
  if [ "$should_exist" = "exists" ]; then
    if [ "$branch_exists" -gt 0 ]; then
      success "Git branch exists: $name"
    else
      fail "Git branch not found: $name"
    fi
  else
    if [ "$branch_exists" -eq 0 ]; then
      success "Git branch cleaned: $name"
    else
      fail "Git branch still exists: $name"
    fi
  fi
}

# 验证Portainer endpoint
verify_portainer_endpoint() {
  local name=$1
  local should_exist=$2
  
  # Portainer endpoint名称去掉连字符
  local endpoint_name=$(echo "$name" | tr -d '-')
  
  if ! docker ps | grep -q "portainer-ce"; then
    info "Skipping Portainer verification (not running)"
    return
  fi
  
  # 需要Portainer API访问，暂时跳过详细验证
  # TODO: 实现完整的Portainer API验证
  info "Portainer endpoint verification: $endpoint_name (TODO)"
}

echo "========================================"
echo "WebUI End-to-End Test Suite"
echo "========================================"
echo ""

# 前置检查
info "Checking prerequisites..."
if ! check_webui; then
  echo "Prerequisites check failed"
  exit 1
fi

# 测试1: 列出集群（应包含devops）
echo ""
info "[1/5] Testing GET /api/clusters (list all)"

clusters=$(timeout 10 curl -s "$API_URL/clusters" 2>/dev/null || echo "[]")
cluster_count=$(echo "$clusters" | jq '. | length')

if [ "$cluster_count" -gt 0 ]; then
  success "API returned $cluster_count cluster(s)"
  
  # 检查是否包含devops
  if echo "$clusters" | jq -e '.[] | select(.name=="devops")' > /dev/null 2>&1; then
    success "devops cluster is listed"
  else
    fail "devops cluster not in list"
  fi
else
  info "No clusters in database (expected in fresh environment)"
fi

# 测试2: 创建集群（通过WebUI）
echo ""
info "[2/5] Testing POST /api/clusters (create cluster)"

TEST_CLUSTER="test-webui-e2e"
TEST_PROVIDER="k3d"

# 检查是否已存在
if k3d cluster list 2>/dev/null | grep -q "^$TEST_CLUSTER"; then
  info "Cleaning up existing test cluster..."
  k3d cluster delete "$TEST_CLUSTER" 2>/dev/null || true
  sleep 2
fi

# 创建集群
create_payload=$(cat <<EOF
{
  "name": "$TEST_CLUSTER",
  "provider": "$TEST_PROVIDER",
  "node_port": 30080,
  "pf_port": 19999,
  "http_port": 18999,
  "https_port": 18998,
  "cluster_subnet": null,
  "register_portainer": true,
  "haproxy_route": true,
  "register_argocd": true
}
EOF
)

response=$(timeout 15 curl -s -X POST "$API_URL/clusters" \
  -H "Content-Type: application/json" \
  -d "$create_payload" 2>/dev/null || echo '{"task_id": null}')

task_id=$(echo "$response" | jq -r '.task_id')

if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
  success "Create task initiated: $task_id"
  
  info "Waiting for cluster creation (max 5min)..."
  if wait_for_task "$task_id"; then
    success "Cluster creation task completed"
    
    # 验证四源
    info "Verifying all sources..."
    sleep 5  # 等待资源完全创建
    
    verify_db_record "$TEST_CLUSTER" "exists"
    verify_k8s_cluster "$TEST_CLUSTER" "$TEST_PROVIDER" "exists"
    verify_git_branch "$TEST_CLUSTER" "exists"
    verify_portainer_endpoint "$TEST_CLUSTER" "exists"
  else
    fail "Cluster creation task failed"
  fi
else
  fail "Failed to create task (response: $response)"
fi

# 测试3: 查看集群详情
echo ""
info "[3/5] Testing GET /api/clusters/{name} (cluster details)"

if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
  cluster_detail=$(timeout 10 curl -s "$API_URL/clusters/$TEST_CLUSTER" 2>/dev/null || echo 'null')
  
  if echo "$cluster_detail" | jq -e '.name' > /dev/null 2>&1; then
    detail_name=$(echo "$cluster_detail" | jq -r '.name')
    detail_status=$(echo "$cluster_detail" | jq -r '.status')
    
    if [ "$detail_name" = "$TEST_CLUSTER" ]; then
      success "Cluster detail returned correctly"
      info "  Status: $detail_status"
    else
      fail "Cluster name mismatch: $detail_name"
    fi
  else
    fail "Failed to get cluster details"
  fi
fi

# 测试4: 再次列出集群（应包含新创建的）
echo ""
info "[4/5] Testing GET /api/clusters (verify new cluster listed)"

clusters=$(timeout 10 curl -s "$API_URL/clusters" 2>/dev/null || echo "[]")
if echo "$clusters" | jq -e ".[] | select(.name==\"$TEST_CLUSTER\")" > /dev/null 2>&1; then
  success "New cluster appears in list"
else
  fail "New cluster not in list"
fi

# 测试5: 删除集群
echo ""
info "[5/5] Testing DELETE /api/clusters/{name} (delete cluster)"

delete_response=$(timeout 15 curl -s -X DELETE "$API_URL/clusters/$TEST_CLUSTER" 2>/dev/null || echo '{"task_id": null}')
delete_task_id=$(echo "$delete_response" | jq -r '.task_id')

if [ -n "$delete_task_id" ] && [ "$delete_task_id" != "null" ]; then
  success "Delete task initiated: $delete_task_id"
  
  info "Waiting for cluster deletion (max 5min)..."
  if wait_for_task "$delete_task_id"; then
    success "Cluster deletion task completed"
    
    # 验证四源清理
    info "Verifying cleanup..."
    sleep 10  # 等待清理完成
    
    verify_db_record "$TEST_CLUSTER" "not_exists"
    verify_k8s_cluster "$TEST_CLUSTER" "$TEST_PROVIDER" "not_exists"
    verify_git_branch "$TEST_CLUSTER" "not_exists"
    verify_portainer_endpoint "$TEST_CLUSTER" "not_exists"
  else
    fail "Cluster deletion task failed"
  fi
else
  fail "Failed to create delete task"
fi

# 总结
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

if [ $failed -eq 0 ]; then
  echo -e "${GREEN}✓ All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}✗ Some tests failed${NC}"
  exit 1
fi

