#!/usr/bin/env bash
# Web UI PostgreSQL 集成环境验证脚本

set -Eeuo pipefail

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}✓${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }
info() { echo -e "${YELLOW}➜${NC} $*"; }

echo "════════════════════════════════════════════════════════"
echo "  Web UI PostgreSQL 集成环境验证"
echo "════════════════════════════════════════════════════════"
echo ""

passed=0
failed=0

# 1. 检查容器状态
info "1. 检查容器状态..."
if docker ps | grep -q "kindler-webui-backend.*healthy"; then
    success "Web UI Backend 运行正常"
    ((passed++))
else
    error "Web UI Backend 异常"
    ((failed++))
fi

# 2. 测试健康检查
info "2. 测试健康检查 API..."
health=$(docker exec kindler-webui-backend curl -s http://localhost:8000/api/health 2>/dev/null || echo "")
if echo "$health" | grep -q "healthy"; then
    success "健康检查通过"
    ((passed++))
else
    error "健康检查失败"
    ((failed++))
fi

# 3. 测试数据库连接
info "3. 测试数据库连接..."
docker exec kindler-webui-backend curl -s http://localhost:8000/api/clusters > /dev/null 2>&1
sleep 1
if docker logs kindler-webui-backend 2>&1 | tail -20 | grep -q "Using PostgreSQL backend"; then
    success "PostgreSQL 连接成功"
    ((passed++))
else
    error "PostgreSQL 连接失败"
    ((failed++))
fi

# 4. 测试 PostgreSQL 直接访问
info "4. 测试 PostgreSQL 直接访问..."
if kubectl --context k3d-devops -n paas exec postgresql-0 -- \
   psql -U kindler -d kindler -c "SELECT 1;" > /dev/null 2>&1; then
    success "PostgreSQL 直接连接成功"
    ((passed++))
else
    error "PostgreSQL 直接连接失败"
    ((failed++))
fi

# 5. 测试 API 列出集群
info "5. 测试 API 列出集群..."
clusters=$(docker exec kindler-webui-backend curl -s http://localhost:8000/api/clusters 2>/dev/null || echo "")
if [ -n "$clusters" ]; then
    success "API 列出集群成功"
    echo "   集群数量: $(echo "$clusters" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")"
    ((passed++))
else
    error "API 列出集群失败"
    ((failed++))
fi

# 6. 查看数据库连接详情
info "6. 查看数据库连接详情..."
echo ""
echo "   数据库连接日志："
docker logs kindler-webui-backend 2>&1 | grep -E "(Attempting|PostgreSQL connection|Using.*backend)" | tail -5 | sed 's/^/   /'
echo ""

# 总结
echo "════════════════════════════════════════════════════════"
echo "  验证结果"
echo "════════════════════════════════════════════════════════"
echo "  通过: $passed"
echo "  失败: $failed"
echo ""

if [ $failed -eq 0 ]; then
    success "所有验证通过！环境可以使用"
    echo ""
    echo "您可以开始使用以下功能："
    echo "  • 查看集群: docker exec kindler-webui-backend curl -s http://localhost:8000/api/clusters"
    echo "  • 健康检查: docker exec kindler-webui-backend curl -s http://localhost:8000/api/health"
    echo "  • 查看日志: docker logs -f kindler-webui-backend"
    echo ""
    echo "详细使用指南: cat ENVIRONMENT_READY.md"
    exit 0
else
    error "部分验证失败，请检查环境配置"
    exit 1
fi


