#!/usr/bin/env bash
# 全面的 Web UI E2E 测试
# 不仅检查 HTTP 状态码，还要验证功能

set -Eeuo pipefail

FRONTEND_URL="${FRONTEND_URL:-http://172.17.0.5}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass_count=0
fail_count=0

log_pass() {
  echo -e "${GREEN}✓${NC} $*"
  pass_count=$((pass_count + 1))
}

log_fail() {
  echo -e "${RED}✗${NC} $*"
  fail_count=$((fail_count + 1))
}

log_warn() {
  echo -e "${YELLOW}⚠${NC} $*"
}

echo "════════════════════════════════════════════════════════════"
echo "Web UI 端到端测试 (E2E)"
echo "前端地址: $FRONTEND_URL"
echo "════════════════════════════════════════════════════════════"
echo

# ============================================================================
# 测试 1: 基础 HTTP 访问
# ============================================================================
echo "【测试 1】基础 HTTP 访问"
echo "────────────────────────────────────────────────────────────"

status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL/" || echo "000")
if [ "$status" = "200" ]; then
  log_pass "HTTP 200 OK"
else
  log_fail "HTTP status: $status (expected 200)"
fi

# 检查 Content-Type
content_type=$(curl -s -I "$FRONTEND_URL/" 2>/dev/null | grep -i "content-type" | cut -d' ' -f2- | tr -d '\r' || echo "unknown")
if echo "$content_type" | grep -qi "text/html"; then
  log_pass "Content-Type: text/html"
else
  log_fail "Content-Type: $content_type (expected text/html)"
fi
echo

# ============================================================================
# 测试 2: HTML 内容验证
# ============================================================================
echo "【测试 2】HTML 内容验证"
echo "────────────────────────────────────────────────────────────"

html=$(curl -s "$FRONTEND_URL/")

# 检查标题
if echo "$html" | grep -q "Kindler"; then
  log_pass "页面标题包含 'Kindler'"
else
  log_fail "页面标题不包含 'Kindler'"
fi

# 检查 Vue app 容器
if echo "$html" | grep -q '<div id="app">'; then
  log_pass "Vue app 容器存在 (#app)"
else
  log_fail "Vue app 容器不存在"
fi

# 检查 JavaScript 引用
if echo "$html" | grep -qE 'src=".*\.js"'; then
  js_file=$(echo "$html" | grep -oE '/assets/index-[^"]+\.js' | head -1)
  log_pass "JavaScript 文件引用: $js_file"
  
  # 验证 JavaScript 文件可访问
  js_status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL$js_file" || echo "000")
  if [ "$js_status" = "200" ]; then
    log_pass "JavaScript 文件可访问 (HTTP $js_status)"
  else
    log_fail "JavaScript 文件不可访问 (HTTP $js_status)"
  fi
else
  log_fail "未找到 JavaScript 文件引用"
fi

# 检查 CSS 引用
if echo "$html" | grep -qE 'href=".*\.css"'; then
  css_file=$(echo "$html" | grep -oE '/assets/index-[^"]+\.css' | head -1)
  log_pass "CSS 文件引用: $css_file"
  
  # 验证 CSS 文件可访问
  css_status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL$css_file" || echo "000")
  if [ "$css_status" = "200" ]; then
    log_pass "CSS 文件可访问 (HTTP $css_status)"
  else
    log_fail "CSS 文件不可访问 (HTTP $css_status)"
  fi
else
  log_fail "未找到 CSS 文件引用"
fi
echo

# ============================================================================
# 测试 3: API 代理功能
# ============================================================================
echo "【测试 3】API 代理功能"
echo "────────────────────────────────────────────────────────────"

# 测试健康检查
health_status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL/api/health" || echo "000")
if [ "$health_status" = "200" ]; then
  log_pass "健康检查 API: HTTP $health_status"
  
  health_json=$(curl -s "$FRONTEND_URL/api/health")
  if echo "$health_json" | jq -e '.status == "healthy"' >/dev/null 2>&1; then
    log_pass "健康检查返回: status=healthy"
  else
    log_fail "健康检查状态异常: $health_json"
  fi
else
  log_fail "健康检查 API 失败: HTTP $health_status"
fi

# 测试配置 API
config_status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL/api/config" || echo "000")
if [ "$config_status" = "200" ]; then
  log_pass "配置 API: HTTP $config_status"
  
  config_json=$(curl -s "$FRONTEND_URL/api/config")
  provider_count=$(echo "$config_json" | jq '.providers | length' 2>/dev/null || echo "0")
  if [ "$provider_count" -ge 2 ]; then
    log_pass "配置包含 $provider_count 个 provider"
  else
    log_fail "配置 provider 数量异常: $provider_count"
  fi
else
  log_fail "配置 API 失败: HTTP $config_status"
fi

# 测试集群列表 API
clusters_status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL/api/clusters" || echo "000")
if [ "$clusters_status" = "200" ]; then
  log_pass "集群列表 API: HTTP $clusters_status"
  
  clusters_json=$(curl -s "$FRONTEND_URL/api/clusters")
  cluster_count=$(echo "$clusters_json" | jq 'length' 2>/dev/null || echo "0")
  if [ "$cluster_count" -gt 0 ]; then
    log_pass "集群列表包含 $cluster_count 个集群"
    
    # 验证集群数据结构
    first_cluster=$(echo "$clusters_json" | jq '.[0]' 2>/dev/null)
    if echo "$first_cluster" | jq -e '.name' >/dev/null 2>&1; then
      cluster_name=$(echo "$first_cluster" | jq -r '.name')
      log_pass "第一个集群: $cluster_name"
    else
      log_fail "集群数据结构异常"
    fi
  else
    log_warn "集群列表为空（Demo 模式可能未初始化）"
  fi
else
  log_fail "集群列表 API 失败: HTTP $clusters_status"
fi
echo

# ============================================================================
# 测试 4: CORS 和跨域请求
# ============================================================================
echo "【测试 4】CORS 配置"
echo "────────────────────────────────────────────────────────────"

# 检查 CORS 头
cors_headers=$(curl -s -I -H "Origin: http://example.com" "$FRONTEND_URL/api/health" | grep -i "access-control" || echo "")
if [ -n "$cors_headers" ]; then
  log_pass "CORS 头存在"
else
  log_warn "未检测到 CORS 头（可能不影响同域访问）"
fi
echo

# ============================================================================
# 测试 5: WebSocket 连接（可选）
# ============================================================================
echo "【测试 5】WebSocket 端点"
echo "────────────────────────────────────────────────────────────"

# 注意：WebSocket 测试需要专门工具，这里只检查端点是否响应
log_warn "WebSocket 完整测试需要 wscat 工具"
log_warn "端点: ws://${FRONTEND_URL#http://}/ws/tasks"
echo

# ============================================================================
# 测试 6: 错误处理
# ============================================================================
echo "【测试 6】错误处理"
echo "────────────────────────────────────────────────────────────"

# 测试不存在的 API 端点
not_found_status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL/api/nonexistent" || echo "000")
if [ "$not_found_status" = "404" ]; then
  log_pass "不存在的端点返回 404"
else
  log_warn "不存在的端点返回: HTTP $not_found_status"
fi

# 测试不存在的静态文件
not_found_static=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL/nonexistent.html" || echo "000")
if [ "$not_found_static" = "200" ]; then
  log_pass "SPA 路由正常（所有路径返回 index.html）"
else
  log_warn "静态文件 404 处理: HTTP $not_found_static"
fi
echo

# ============================================================================
# 测试 7: 性能和响应时间
# ============================================================================
echo "【测试 7】性能指标"
echo "────────────────────────────────────────────────────────────"

# 测试首页响应时间
response_time=$(curl -s -o /dev/null -w "%{time_total}" "$FRONTEND_URL/")
log_pass "首页响应时间: ${response_time}s"

# 测试 API 响应时间
api_time=$(curl -s -o /dev/null -w "%{time_total}" "$FRONTEND_URL/api/health")
log_pass "API 响应时间: ${api_time}s"
echo

# ============================================================================
# 汇总结果
# ============================================================================
echo "════════════════════════════════════════════════════════════"
echo "测试结果汇总"
echo "════════════════════════════════════════════════════════════"
echo -e "${GREEN}通过: $pass_count${NC}"
echo -e "${RED}失败: $fail_count${NC}"
echo

if [ $fail_count -eq 0 ]; then
  echo -e "${GREEN}✓ 所有测试通过！${NC}"
  exit 0
else
  echo -e "${RED}✗ 有 $fail_count 个测试失败${NC}"
  echo
  echo "建议检查项："
  echo "1. 前端容器是否正确构建和运行"
  echo "2. Nginx 配置是否正确（API 代理、SPA 路由）"
  echo "3. 后端服务是否可访问"
  echo "4. 浏览器控制台是否有 JavaScript 错误"
  echo "5. 网络连接是否正常"
  exit 1
fi

