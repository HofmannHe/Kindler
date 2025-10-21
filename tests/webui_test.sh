#!/usr/bin/env bash
# Web UI 集成测试脚本
# 测试 Web UI API 端点、WebSocket 连接和基本功能

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../config/clusters.env
source "${PROJECT_ROOT}/config/clusters.env" 2>/dev/null || true

BASE_DOMAIN="${BASE_DOMAIN:-192.168.51.30.sslip.io}"
WEBUI_URL="http://kindler.devops.${BASE_DOMAIN}"
WEBUI_API_URL="${WEBUI_URL}/api"

PASSED=0
FAILED=0

log_pass() {
    echo "✓ $1"
    ((PASSED++))
}

log_fail() {
    echo "✗ $1"
    ((FAILED++))
}

log_info() {
    echo "ℹ $1"
}

# Test 1: Web UI HTTP 可达性
test_webui_http_reachability() {
    log_info "Testing Web UI HTTP reachability..."
    
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "${WEBUI_URL}" 2>/dev/null || echo "000")
    
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "302" ]; then
        log_pass "Web UI is reachable (HTTP ${http_code})"
        return 0
    else
        log_fail "Web UI is not reachable (HTTP ${http_code})"
        return 1
    fi
}

# Test 2: API Health Check
test_api_health() {
    log_info "Testing API health endpoint..."
    
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "${WEBUI_API_URL}/health" 2>/dev/null || echo "000")
    
    if [ "${http_code}" = "200" ]; then
        log_pass "API health check passed (HTTP ${http_code})"
        return 0
    else
        log_fail "API health check failed (HTTP ${http_code})"
        return 1
    fi
}

# Test 3: List Clusters API
test_list_clusters_api() {
    log_info "Testing GET /api/clusters endpoint..."
    
    local response
    response=$(curl -s -m 10 "${WEBUI_API_URL}/clusters" 2>/dev/null || echo "")
    
    # API returns a JSON array directly (not wrapped in object)
    if echo "${response}" | grep -qE '^\[.*\]$'; then
        log_pass "GET /api/clusters returned valid JSON array"
        
        # 统计集群数量
        local count
        count=$(echo "${response}" | grep -o '"name"' | wc -l || echo "0")
        log_info "Found ${count} clusters in database"
        
        return 0
    else
        log_fail "GET /api/clusters returned invalid response"
        echo "Response: ${response}"
        return 1
    fi
}

# Test 4: Backend Service Connectivity
test_backend_connectivity() {
    log_info "Testing backend service connectivity..."
    
    # 检查 /api/config 端点（验证 backend 服务可达）
    local config
    config=$(curl -s -m 10 "${WEBUI_API_URL}/config" 2>/dev/null || echo "")
    
    if echo "${config}" | grep -q '"base_domain"'; then
        log_pass "Backend service is reachable and responding"
        return 0
    else
        log_fail "Backend service is not responding correctly"
        echo "Response: ${config}"
        return 1
    fi
}

# Test 5: API Error Handling
test_api_error_handling() {
    log_info "Testing API error handling..."
    
    # 尝试获取不存在的集群
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "${WEBUI_API_URL}/clusters/nonexistent-cluster-12345" 2>/dev/null || echo "000")
    
    if [ "${http_code}" = "404" ]; then
        log_pass "API correctly returns 404 for nonexistent cluster"
        return 0
    else
        log_fail "API error handling incorrect (HTTP ${http_code}, expected 404)"
        return 1
    fi
}

# Test 6: HAProxy Routing
test_haproxy_routing() {
    log_info "Testing HAProxy routing for Web UI..."
    
    # 检查 HAProxy 是否正确路由到 Web UI
    local response
    response=$(curl -s -H "Host: kindler.devops.${BASE_DOMAIN}" -m 10 "http://192.168.51.30/" 2>/dev/null || echo "")
    
    if echo "${response}" | grep -qi "kindler\|vue\|<!DOCTYPE html>"; then
        log_pass "HAProxy correctly routes to Web UI"
        return 0
    else
        log_fail "HAProxy routing to Web UI failed"
        echo "Response: ${response:0:200}"
        return 1
    fi
}

# Main test execution
main() {
    echo "========================================"
    echo "Web UI Integration Test Suite"
    echo "========================================"
    echo ""
    
    # 前置检查
    log_info "Web UI URL: ${WEBUI_URL}"
    log_info "API URL: ${WEBUI_API_URL}"
    echo ""
    
    # 执行测试
    test_webui_http_reachability || true
    test_api_health || true
    test_list_clusters_api || true
    test_backend_connectivity || true
    test_api_error_handling || true
    test_haproxy_routing || true
    
    # 总结
    echo ""
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo "Passed: ${PASSED}"
    echo "Failed: ${FAILED}"
    echo ""
    
    if [ "${FAILED}" -eq 0 ]; then
        echo "✓ All tests passed!"
        return 0
    else
        echo "✗ ${FAILED} test(s) failed"
        return 1
    fi
}

main "$@"

