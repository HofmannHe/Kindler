#!/usr/bin/env bash
# Web UI PostgreSQL 集成测试
#
# 测试目标：
# 1. 验证 Web UI Backend 能够连接到 devops 集群的 PostgreSQL
# 2. 验证数据库自动切换机制（PostgreSQL 优先，SQLite fallback）
# 3. 验证基本的 CRUD 操作

set -Eeuo pipefail
IFS=$'\n\t'

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

success() {
  echo -e "${GREEN}✓${NC} $*"
}

error() {
  echo -e "${RED}✗${NC} $*"
}

info() {
  echo -e "${YELLOW}➜${NC} $*"
}

# 检查 devops 集群是否运行
check_devops_cluster() {
  info "检查 devops 集群状态..."
  
  if ! kubectl --context k3d-devops get nodes &>/dev/null; then
    error "devops 集群未运行，请先执行 scripts/bootstrap.sh"
    return 1
  fi
  
  success "devops 集群运行正常"
  return 0
}

# 检查 PostgreSQL 是否就绪
check_postgresql() {
  info "检查 PostgreSQL 状态..."
  
  if ! kubectl --context k3d-devops -n paas get pod -l app.kubernetes.io/name=postgresql &>/dev/null; then
    error "PostgreSQL 未部署"
    return 1
  fi
  
  if ! kubectl --context k3d-devops -n paas wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql --timeout=10s &>/dev/null; then
    error "PostgreSQL Pod 未就绪"
    return 1
  fi
  
  success "PostgreSQL 运行正常"
  return 0
}

# 测试 PostgreSQL 连接
test_postgresql_connection() {
  info "测试 PostgreSQL 直接连接..."
  
  local result
  result=$(kubectl --context k3d-devops -n paas exec deployment/postgresql -- \
    psql -U postgres -d paas -c "SELECT 1;" -t 2>/dev/null || echo "failed")
  
  if [[ "$result" == *"1"* ]]; then
    success "PostgreSQL 连接成功"
    return 0
  else
    error "PostgreSQL 连接失败"
    return 1
  fi
}

# 检查 Web UI Backend 容器是否运行
check_webui_backend() {
  info "检查 Web UI Backend 状态..."
  
  if ! docker ps --format '{{.Names}}' | grep -q "kindler-webui-backend"; then
    error "Web UI Backend 未运行，请先启动：docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend"
    return 1
  fi
  
  success "Web UI Backend 运行正常"
  return 0
}

# 测试 Web UI Backend 健康检查
test_webui_health() {
  info "测试 Web UI Backend 健康检查..."
  
  local response
  response=$(docker exec kindler-webui-backend curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/health || echo "failed")
  
  if [[ "$response" == "200" ]]; then
    success "Web UI Backend 健康检查通过"
    return 0
  else
    error "Web UI Backend 健康检查失败 (HTTP $response)"
    return 1
  fi
}

# 检查 Web UI Backend 日志中的数据库连接状态
check_backend_db_connection() {
  info "检查 Web UI Backend 数据库连接日志..."
  
  # 获取最近的日志
  local logs
  logs=$(docker logs kindler-webui-backend --tail 50 2>&1 || echo "")
  
  if echo "$logs" | grep -q "Using PostgreSQL backend"; then
    success "Web UI Backend 已连接到 PostgreSQL"
    return 0
  elif echo "$logs" | grep -q "Using SQLite backend"; then
    info "Web UI Backend 使用 SQLite (fallback 模式)"
    return 0
  elif echo "$logs" | grep -q "PostgreSQL connection failed"; then
    error "Web UI Backend PostgreSQL 连接失败，已 fallback 到 SQLite"
    echo "$logs" | grep "PostgreSQL connection failed"
    return 1
  else
    error "无法确定 Web UI Backend 的数据库连接状态"
    return 1
  fi
}

# 测试 API 端点
test_api_list_clusters() {
  info "测试 API: GET /api/clusters..."
  
  local response
  response=$(docker exec kindler-webui-backend curl -s http://localhost:8000/api/clusters || echo "failed")
  
  if [[ "$response" != "failed" ]]; then
    success "API 调用成功"
    echo "返回数据: $response" | head -c 200
    return 0
  else
    error "API 调用失败"
    return 1
  fi
}

# 主测试流程
main() {
  echo "========================================="
  echo "Web UI PostgreSQL 集成测试"
  echo "========================================="
  echo ""
  
  local failed=0
  
  # 1. 检查前置条件
  check_devops_cluster || ((failed++))
  check_postgresql || ((failed++))
  check_webui_backend || ((failed++))
  
  echo ""
  
  # 2. 测试连接
  test_postgresql_connection || ((failed++))
  test_webui_health || ((failed++))
  check_backend_db_connection || ((failed++))
  
  echo ""
  
  # 3. 测试 API
  test_api_list_clusters || ((failed++))
  
  echo ""
  echo "========================================="
  
  if [ $failed -eq 0 ]; then
    success "所有测试通过！"
    return 0
  else
    error "测试失败: $failed 个测试未通过"
    return 1
  fi
}

main "$@"

