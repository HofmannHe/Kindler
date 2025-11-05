#!/usr/bin/env bash
# Web GUI 验收测试脚本
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

BASE_DOMAIN="${BASE_DOMAIN:-192.168.51.30.sslip.io}"
WEBUI_URL="http://kindler.devops.${BASE_DOMAIN}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $*"
}

log_error() {
  echo -e "${RED}[✗]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[!]${NC} $*"
}

check_service() {
  local service="$1"
  if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
    log_success "Service $service is running"
    return 0
  else
    log_error "Service $service is NOT running"
    return 1
  fi
}

check_http() {
  local url="$1"
  local expected_code="${2:-200}"
  
  log_info "Checking $url (expecting $expected_code)"
  
  local status_code
  status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "000")
  
  if [[ "$status_code" == "$expected_code" ]]; then
    log_success "HTTP $expected_code OK"
    return 0
  else
    log_error "Expected $expected_code, got $status_code"
    return 1
  fi
}

check_http_contains() {
  local url="$1"
  local keyword="$2"
  
  log_info "Checking $url contains '$keyword'"
  
  local content
  content=$(curl -s "$url" || echo "")
  
  if echo "$content" | grep -q "$keyword"; then
    log_success "Content contains '$keyword'"
    return 0
  else
    log_error "Content does NOT contain '$keyword'"
    return 1
  fi
}

check_api_json() {
  local url="$1"
  local jq_filter="$2"
  local expected="$3"
  
  log_info "Checking API $url: $jq_filter == $expected"
  
  local result
  result=$(curl -s "$url" | jq -r "$jq_filter" || echo "")
  
  if [[ "$result" == "$expected" ]]; then
    log_success "API check passed: $result"
    return 0
  else
    log_error "Expected '$expected', got '$result'"
    return 1
  fi
}

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         Kindler Web GUI 验收测试                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo

# Test 1: 检查服务运行状态
echo "===== Test 1: 服务运行状态 ====="
check_service "kindler-webui-backend" || exit 1
check_service "kindler-webui-frontend" || exit 1
check_service "haproxy-gw" || exit 1
echo

# Test 2: 检查前端可访问性
echo "===== Test 2: 前端访问测试 ====="
check_http "$WEBUI_URL" 200 || exit 1
check_http_contains "$WEBUI_URL" "Kindler" || exit 1
echo

# Test 3: 检查 API 健康检查
echo "===== Test 3: API 健康检查 ====="
check_http "$WEBUI_URL/api/health" 200 || exit 1
check_api_json "$WEBUI_URL/api/health" ".status" "healthy" || exit 1
echo

# Test 4: 检查 API 配置端点
echo "===== Test 4: API 配置端点 ====="
check_http "$WEBUI_URL/api/config" 200 || exit 1
check_api_json "$WEBUI_URL/api/config" ".base_domain" "$BASE_DOMAIN" || exit 1
check_api_json "$WEBUI_URL/api/config" ".providers | length" "2" || exit 1
echo

# Test 5: 检查集群列表 API
echo "===== Test 5: 集群列表 API ====="
check_http "$WEBUI_URL/api/clusters" 200 || exit 1
log_info "Cluster count: $(curl -s "$WEBUI_URL/api/clusters" | jq 'length')"
echo

# Test 6: 检查 WebSocket 端点可访问
echo "===== Test 6: WebSocket 端点 ====="
log_info "WebSocket endpoint: ws://kindler.devops.$BASE_DOMAIN/ws/tasks"
log_warn "WebSocket 连接测试需要 wscat 工具，跳过自动测试"
log_info "手动测试: wscat -c ws://kindler.devops.$BASE_DOMAIN/ws/tasks"
echo

# Test 7: 检查 Docker 网络连接
echo "===== Test 7: Docker 网络连接 ====="
if docker network inspect k3d-shared &>/dev/null; then
  log_success "k3d-shared network exists"
  
  # Check if backend is connected
  if docker inspect kindler-webui-backend | jq -r '.[0].NetworkSettings.Networks | keys[]' | grep -q "k3d-shared"; then
    log_success "Backend connected to k3d-shared network"
  else
    log_error "Backend NOT connected to k3d-shared network"
    exit 1
  fi
else
  log_error "k3d-shared network does NOT exist"
  exit 1
fi
echo

# Test 8: 检查 HAProxy 路由配置
echo "===== Test 8: HAProxy 路由配置 ====="
if docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep -q "host_kindler"; then
  log_success "HAProxy has kindler ACL"
else
  log_error "HAProxy missing kindler ACL"
  exit 1
fi

if docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep -q "be_kindler"; then
  log_success "HAProxy has kindler backend"
else
  log_error "HAProxy missing kindler backend"
  exit 1
fi
echo

# Test 9: 检查后端可以访问 kubectl
echo "===== Test 9: Backend kubectl 访问 ====="
if docker exec kindler-webui-backend kubectl version --client &>/dev/null; then
  log_success "kubectl is available in backend"
else
  log_error "kubectl NOT available in backend"
  exit 1
fi
echo

# Test 10: 检查后端可以访问脚本
echo "===== Test 10: Backend scripts 访问 ====="
if docker exec kindler-webui-backend ls /app/scripts/create_env.sh &>/dev/null; then
  log_success "Scripts are mounted in backend"
else
  log_error "Scripts NOT mounted in backend"
  exit 1
fi
echo

echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  所有验收测试通过! ✅                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo
echo "🎉 Web GUI 已准备就绪！"
echo
echo "访问地址: $WEBUI_URL"
echo "API 文档: $WEBUI_URL/docs"
echo
echo "下一步："
echo "1. 在浏览器中访问 $WEBUI_URL"
echo "2. 尝试创建一个测试集群"
echo "3. 验证实时进度更新"
echo "4. 验证集群自动注册到 Portainer 和 ArgoCD"
echo "5. 删除测试集群验证清理流程"

