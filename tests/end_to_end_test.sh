#!/usr/bin/env bash
# 完整的端到端测试脚本
# 覆盖：脚本创建、WebUI 创建、Portainer、ArgoCD、whoami 服务、幂等性

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

TEST_REPORT="/tmp/e2e_test_report.txt"
FAILED_TESTS=0
PASSED_TESTS=0

# 清理函数
cleanup() {
  echo ""
  echo "=========================================="
  echo "  清理测试资源"
  echo "=========================================="
  
  for name in e2e-script-k3d e2e-script-kind e2e-webui-k3d e2e-webui-kind; do
    if kubectl config get-contexts -o name 2>/dev/null | grep -qE "k3d-${name}|kind-${name}"; then
      echo "  清理集群: $name"
      "$ROOT_DIR/scripts/delete_env.sh" -n "$name" 2>/dev/null || true
    fi
  done
}

trap cleanup EXIT

# 测试函数
test_check() {
  local name="$1"
  local result="$2"
  local details="${3:-}"
  
  if [ "$result" -eq 0 ]; then
    echo "  ✓ $name" | tee -a "$TEST_REPORT"
    if [ -n "$details" ]; then
      echo "    $details" | tee -a "$TEST_REPORT"
    fi
    PASSED_TESTS=$((PASSED_TESTS + 1))
  else
    echo "  ✗ $name" | tee -a "$TEST_REPORT"
    if [ -n "$details" ]; then
      echo "    $details" | tee -a "$TEST_REPORT"
    fi
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
}

echo "=========================================="
echo "  完整端到端测试"
echo "=========================================="
echo "开始时间: $(date)"
echo "测试报告: $TEST_REPORT"
echo "" | tee "$TEST_REPORT"

# ============================================
# 测试 1: 脚本创建集群 (k3d)
# ============================================
echo "[测试 1] 脚本创建 k3d 集群"
if "$ROOT_DIR/scripts/create_env.sh" -n e2e-script-k3d -p k3d >/tmp/e2e_script_k3d.log 2>&1; then
  # 验证集群存在
  if kubectl --context k3d-e2e-script-k3d get nodes >/dev/null 2>&1; then
    # 验证数据库记录
    if sqlite_cluster_exists "e2e-script-k3d" 2>/dev/null; then
      test_check "脚本创建 k3d 集群" 0 "集群存在且数据库记录正确"
    else
      test_check "脚本创建 k3d 集群" 1 "集群存在但数据库无记录"
    fi
  else
    test_check "脚本创建 k3d 集群" 1 "集群创建失败"
  fi
else
  test_check "脚本创建 k3d 集群" 1 "create_env.sh 失败"
fi
echo ""

# ============================================
# 测试 2: 脚本创建集群 (kind)
# ============================================
echo "[测试 2] 脚本创建 kind 集群"
if "$ROOT_DIR/scripts/create_env.sh" -n e2e-script-kind -p kind >/tmp/e2e_script_kind.log 2>&1; then
  # 验证集群存在
  if kubectl --context kind-e2e-script-kind get nodes >/dev/null 2>&1; then
    # 验证数据库记录
    if sqlite_cluster_exists "e2e-script-kind" 2>/dev/null; then
      test_check "脚本创建 kind 集群" 0 "集群存在且数据库记录正确"
    else
      test_check "脚本创建 kind 集群" 1 "集群存在但数据库无记录"
    fi
  else
    test_check "脚本创建 kind 集群" 1 "集群创建失败"
  fi
else
  test_check "脚本创建 kind 集群" 1 "create_env.sh 失败"
fi
echo ""

# ============================================
# 测试 3: WebUI API 创建集群 (k3d)
# ============================================
echo "[测试 3] WebUI API 创建 k3d 集群"
webui_response=$(curl -s -X POST "http://localhost:8000/api/clusters" \
  -H "Content-Type: application/json" \
  -d '{"name":"e2e-webui-k3d","provider":"k3d"}' 2>&1 || echo "")

if echo "$webui_response" | grep -q '"task_id"'; then
  task_id=$(echo "$webui_response" | grep -o '"task_id":"[^"]*"' | cut -d'"' -f4)
  echo "  任务已创建: $task_id"
  
  # 等待任务完成（最多180秒）
  max_wait=180
  elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    
    # 检查集群是否已创建
    if kubectl --context k3d-e2e-webui-k3d get nodes >/dev/null 2>&1; then
      if sqlite_cluster_exists "e2e-webui-k3d" 2>/dev/null; then
        test_check "WebUI API 创建 k3d 集群" 0 "集群创建成功（${elapsed}秒）"
      else
        test_check "WebUI API 创建 k3d 集群" 1 "集群创建但数据库无记录"
      fi
      break
    fi
    
    if [ $elapsed -ge $max_wait ]; then
      test_check "WebUI API 创建 k3d 集群" 1 "超时（${max_wait}秒）"
    fi
  done
else
  test_check "WebUI API 创建 k3d 集群" 1 "API 调用失败: $webui_response"
fi
echo ""

# ============================================
# 测试 4: WebUI API 创建集群 (kind)
# ============================================
echo "[测试 4] WebUI API 创建 kind 集群"
webui_response=$(curl -s -X POST "http://localhost:8000/api/clusters" \
  -H "Content-Type: application/json" \
  -d '{"name":"e2e-webui-kind","provider":"kind"}' 2>&1 || echo "")

if echo "$webui_response" | grep -q '"task_id"'; then
  task_id=$(echo "$webui_response" | grep -o '"task_id":"[^"]*"' | cut -d'"' -f4)
  echo "  任务已创建: $task_id"
  
  # 等待任务完成（最多180秒）
  max_wait=180
  elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    
    # 检查集群是否已创建
    if kubectl --context kind-e2e-webui-kind get nodes >/dev/null 2>&1; then
      if sqlite_cluster_exists "e2e-webui-kind" 2>/dev/null; then
        test_check "WebUI API 创建 kind 集群" 0 "集群创建成功（${elapsed}秒）"
      else
        test_check "WebUI API 创建 kind 集群" 1 "集群创建但数据库无记录"
      fi
      break
    fi
    
    if [ $elapsed -ge $max_wait ]; then
      test_check "WebUI API 创建 kind 集群" 1 "超时（${max_wait}秒）"
    fi
  done
else
  test_check "WebUI API 创建 kind 集群" 1 "API 调用失败: $webui_response"
fi
echo ""

# ============================================
# 测试 5: Portainer 集群可见性
# ============================================
echo "[测试 5] Portainer 集群可见性"
# TODO: 需要 Portainer API token 才能测试
# 目前只能提供手动验证提示
echo "  ⚠ Portainer API 测试需要手动验证"
echo "  验证方法: 访问 Portainer UI，检查 Edge Agents 页面"
echo "  预期: 应该能看到 e2e-script-k3d, e2e-script-kind, e2e-webui-k3d, e2e-webui-kind"
echo ""

# ============================================
# 测试 6: ArgoCD Applications 状态
# ============================================
echo "[测试 6] ArgoCD Applications 状态"
for cluster in e2e-script-k3d e2e-script-kind e2e-webui-k3d e2e-webui-kind; do
  if kubectl --context k3d-devops get application "whoami-${cluster}" -n argocd >/dev/null 2>&1; then
    # 检查同步状态
    sync_status=$(kubectl --context k3d-devops get application "whoami-${cluster}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    health_status=$(kubectl --context k3d-devops get application "whoami-${cluster}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
      test_check "ArgoCD Application: $cluster" 0 "Synced & Healthy"
    else
      test_check "ArgoCD Application: $cluster" 1 "Sync: $sync_status, Health: $health_status"
    fi
  else
    test_check "ArgoCD Application: $cluster" 1 "Application 不存在"
  fi
done
echo ""

# ============================================
# 测试 7: whoami 服务可用性
# ============================================
echo "[测试 7] whoami 服务可用性"
for cluster in e2e-script-k3d e2e-script-kind e2e-webui-k3d e2e-webui-kind; do
  # 确定 context
  ctx=""
  provider=$(sqlite_query "SELECT provider FROM clusters WHERE name = '$cluster';" 2>/dev/null | head -1 | tr -d ' \n' || echo "k3d")
  if [ "$provider" = "k3d" ]; then
    ctx="k3d-${cluster}"
  else
    ctx="kind-${cluster}"
  fi
  
  # 检查 whoami pod
  if kubectl --context "$ctx" get pods -n whoami >/dev/null 2>&1; then
    pod_count=$(kubectl --context "$ctx" get pods -n whoami --field-selector status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$pod_count" -gt 0 ]; then
      # 尝试访问服务
      whoami_url="http://whoami.${cluster}.192.168.51.30.sslip.io"
      if curl -s -m 5 "$whoami_url" >/dev/null 2>&1; then
        test_check "whoami 服务: $cluster" 0 "Running & 可访问"
      else
        test_check "whoami 服务: $cluster" 1 "Running 但不可访问"
      fi
    else
      test_check "whoami 服务: $cluster" 1 "Pod 未运行"
    fi
  else
    test_check "whoami 服务: $cluster" 1 "Namespace 不存在"
  fi
done
echo ""

# ============================================
# 测试 8: 数据一致性
# ============================================
echo "[测试 8] 数据一致性"
if [ -f "$ROOT_DIR/scripts/test_data_consistency.sh" ]; then
  if "$ROOT_DIR/scripts/test_data_consistency.sh" >/tmp/data_consistency_e2e.log 2>&1; then
    test_check "数据一致性测试" 0 "所有检查通过"
  else
    failed_count=$(grep -c "✗" /tmp/data_consistency_e2e.log || echo "0")
    test_check "数据一致性测试" 1 "有 $failed_count 个检查失败"
  fi
else
  test_check "数据一致性测试" 1 "测试脚本不存在"
fi
echo ""

# ============================================
# 测试 9: 幂等性测试
# ============================================
echo "[测试 9] 幂等性测试"

# 9.1 重复创建（应该失败或跳过）
echo "  9.1 重复创建同名集群..."
if "$ROOT_DIR/scripts/create_env.sh" -n e2e-script-k3d -p k3d >/tmp/e2e_duplicate.log 2>&1; then
  # 检查是否真的创建了第二个
  clusters_count=$(k3d cluster list 2>/dev/null | grep -c "e2e-script-k3d" || echo "0")
  if [ "$clusters_count" -eq 1 ]; then
    test_check "重复创建检测" 0 "正确跳过已存在的集群"
  else
    test_check "重复创建检测" 1 "创建了重复集群"
  fi
else
  # 失败也可能是因为检测到已存在
  if grep -q "already exists\|已存在" /tmp/e2e_duplicate.log 2>/dev/null; then
    test_check "重复创建检测" 0 "正确拒绝重复创建"
  else
    test_check "重复创建检测" 1 "未知错误"
  fi
fi

# 9.2 多次运行 cleanup_nonexistent_clusters.sh
echo "  9.2 cleanup_nonexistent_clusters.sh 幂等性..."
result1=$("$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" 2>&1 | tail -1)
result2=$("$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" 2>&1 | tail -1)
if [ "$result1" = "$result2" ]; then
  test_check "cleanup_nonexistent_clusters 幂等性" 0
else
  test_check "cleanup_nonexistent_clusters 幂等性" 1 "多次运行结果不一致"
fi

# 9.3 多次运行 sync_applicationset.sh
echo "  9.3 sync_applicationset.sh 幂等性..."
"$ROOT_DIR/scripts/sync_applicationset.sh" >/tmp/sync1.log 2>&1
result1=$(md5sum "$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml" 2>/dev/null | awk '{print $1}')
sleep 2
"$ROOT_DIR/scripts/sync_applicationset.sh" >/tmp/sync2.log 2>&1
result2=$(md5sum "$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml" 2>/dev/null | awk '{print $1}')
if [ "$result1" = "$result2" ]; then
  test_check "sync_applicationset 幂等性" 0
else
  test_check "sync_applicationset 幂等性" 1 "多次运行生成的 ApplicationSet 不一致"
fi

echo ""

# ============================================
# 汇总结果
# ============================================
echo "=========================================="
echo "  测试结果汇总"
echo "=========================================="
echo "通过: $PASSED_TESTS" | tee -a "$TEST_REPORT"
echo "失败: $FAILED_TESTS" | tee -a "$TEST_REPORT"
echo "总计: $((PASSED_TESTS + FAILED_TESTS))" | tee -a "$TEST_REPORT"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
  echo "=========================================="
  echo "✅ 所有端到端测试通过！"
  echo "=========================================="
  
  # 取消清理（保留测试集群供手动验证）
  trap - EXIT
  
  echo ""
  echo "测试集群已保留，可手动验证:"
  echo "  - e2e-script-k3d (k3d)"
  echo "  - e2e-script-kind (kind)"
  echo "  - e2e-webui-k3d (k3d, 如果创建成功)"
  echo "  - e2e-webui-kind (kind, 如果创建成功)"
  echo ""
  echo "清理测试集群:"
  echo "  scripts/delete_env.sh -n e2e-script-k3d"
  echo "  scripts/delete_env.sh -n e2e-script-kind"
  echo "  scripts/delete_env.sh -n e2e-webui-k3d"
  echo "  scripts/delete_env.sh -n e2e-webui-kind"
  
  exit 0
else
  echo "=========================================="
  echo "✗ 有 $FAILED_TESTS 个测试失败"
  echo "=========================================="
  echo ""
  echo "详细报告: $TEST_REPORT"
  echo "日志文件: /tmp/e2e_*.log"
  exit 1
fi
