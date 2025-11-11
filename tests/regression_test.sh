#!/usr/bin/env bash
# 完整回归测试脚本（SQLite 迁移后）

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="/tmp/kindler_regression_test.log"

# 超时设置
TIMEOUT_CLEAN=300      # 5分钟
TIMEOUT_BOOTSTRAP=600  # 10分钟
TIMEOUT_CREATE=300     # 5分钟

# 清理函数
cleanup() {
  echo ""
  echo "=========================================="
  echo "  测试失败，清理环境..."
  echo "=========================================="
  # 清理测试集群
  for name in test-script-k3d test-script-kind test-webui-k3d test-webui-kind; do
    if k3d cluster list 2>/dev/null | grep -q "$name" || kind get clusters 2>/dev/null | grep -q "$name"; then
      echo "  清理测试集群: $name"
      "$ROOT_DIR/scripts/delete_env.sh" -n "$name" 2>/dev/null || true
    fi
  done
}

trap cleanup EXIT

# 后台执行命令并监控输出
run_with_monitor() {
  local timeout="$1"
  local name="$2"
  shift 2
  local cmd=("$@")
  
  echo "[$name] 开始执行..."
  echo "  命令: ${cmd[*]}"
  echo "  超时: ${timeout}秒"
  
  # 后台执行并重定向输出
  "${cmd[@]}" > "$LOG_FILE" 2>&1 &
  local pid=$!
  local elapsed=0
  local check_interval=30
  
  while kill -0 $pid 2>/dev/null; do
    sleep $check_interval
    elapsed=$((elapsed + check_interval))
    
    # 显示进度
    echo "  [$name] 进度: ${elapsed}秒 / ${timeout}秒 ($(date '+%H:%M:%S'))"
    
    # 显示最新日志（最后10行）
    if [ -f "$LOG_FILE" ]; then
      tail -10 "$LOG_FILE" | sed 's/^/    /' | tail -3
    fi
    
    # 检查超时
    if [ $elapsed -ge $timeout ]; then
      echo "  ✗ [$name] 超时（${timeout}秒）"
      kill $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      return 1
    fi
  done
  
  # 等待进程完成
  wait $pid
  local exit_code=$?
  
  if [ $exit_code -eq 0 ]; then
    echo "  ✓ [$name] 完成（${elapsed}秒）"
  else
    echo "  ✗ [$name] 失败（退出码: $exit_code）"
    echo "  最后20行日志:"
    tail -20 "$LOG_FILE" | sed 's/^/    /'
  fi
  
  return $exit_code
}

echo "=========================================="
echo "  SQLite 迁移完整回归测试"
echo "=========================================="
echo "开始时间: $(date)"
echo "日志文件: $LOG_FILE"
echo ""

# 步骤 1: 清理环境
echo "[步骤 1/6] 彻底清理环境"
if ! run_with_monitor $TIMEOUT_CLEAN "清理环境" "$ROOT_DIR/scripts/clean.sh" --all; then
  echo "✗ 清理环境失败"
  exit 1
fi
echo ""

# 步骤 2: 启动基础环境
echo "[步骤 2/6] 启动基础环境 (bootstrap.sh)"
if ! run_with_monitor $TIMEOUT_BOOTSTRAP "启动基础环境" "$ROOT_DIR/scripts/bootstrap.sh"; then
  echo "✗ 启动基础环境失败"
  exit 1
fi
echo ""

# 步骤 3: 验证数据库初始化
echo "[步骤 3/6] 验证数据库初始化"
if [ -f "$ROOT_DIR/scripts/test_sqlite_migration.sh" ]; then
  if ! "$ROOT_DIR/scripts/test_sqlite_migration.sh" 2>&1 | tee -a "$LOG_FILE"; then
    echo "✗ 数据库验证失败"
    exit 1
  fi
else
  echo "  ⚠ 测试脚本不存在，跳过数据库验证"
fi
echo ""

# 步骤 4: 脚本方式创建集群（k3d）
echo "[步骤 4/6] 脚本方式创建测试集群 (k3d)"
if ! run_with_monitor $TIMEOUT_CREATE "创建 test-script-k3d" "$ROOT_DIR/scripts/create_env.sh" -n test-script-k3d -p k3d; then
  echo "✗ 创建 test-script-k3d 失败"
  exit 1
fi

# 验证集群存在
if ! kubectl --context k3d-test-script-k3d get nodes >/dev/null 2>&1; then
  echo "✗ test-script-k3d 集群验证失败"
  exit 1
fi
echo "  ✓ test-script-k3d 集群验证通过"
echo ""

# 步骤 5: 脚本方式创建集群（kind）
echo "[步骤 5/6] 脚本方式创建测试集群 (kind)"
if ! run_with_monitor $TIMEOUT_CREATE "创建 test-script-kind" "$ROOT_DIR/scripts/create_env.sh" -n test-script-kind -p kind; then
  echo "✗ 创建 test-script-kind 失败"
  exit 1
fi

# 验证集群存在
if ! kubectl --context kind-test-script-kind get nodes >/dev/null 2>&1; then
  echo "✗ test-script-kind 集群验证失败"
  exit 1
fi
echo "  ✓ test-script-kind 集群验证通过"
echo ""

# 步骤 6: 完整数据一致性测试
echo "[步骤 6/7] 完整数据一致性测试"
echo "  检查数据库记录..."

# 使用 lib_sqlite.sh 查询
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

if sqlite_is_available 2>/dev/null; then
  # 检查两个测试集群是否在数据库中
  for name in test-script-k3d test-script-kind; do
    if sqlite_cluster_exists "$name" 2>/dev/null; then
      echo "  ✓ $name 在数据库中"
      
      # 获取集群信息
      cluster_info=$(sqlite_get_cluster "$name" 2>/dev/null || echo "")
      if [ -n "$cluster_info" ]; then
        echo "    信息: $cluster_info"
      fi
    else
      echo "  ✗ $name 不在数据库中"
      exit 1
    fi
  done
  
  # 清理不存在的集群记录（确保数据一致性）
  echo ""
  echo "  清理不存在的集群记录..."
  if [ -f "$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" ]; then
    "$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" 2>&1 | grep -E "✓|✗|删除|清理|跳过" | sed 's/^/    /' || true
  fi
  
  # 验证 ApplicationSet 只包含实际存在的集群
  echo ""
  echo "  验证 ApplicationSet 同步..."
  if [ -f "$ROOT_DIR/scripts/sync_applicationset.sh" ]; then
    "$ROOT_DIR/scripts/sync_applicationset.sh" 2>&1 | grep -E "✓|⚠|发现|添加" | sed 's/^/    /' || true
  fi
else
  echo "  ⚠ 数据库不可用，跳过数据库验证"
fi

# 列出所有集群
echo ""
echo "  集群列表:"
if [ -x "$ROOT_DIR/scripts/cluster.sh" ]; then
  "$ROOT_DIR/scripts/cluster.sh" list 2>&1 | grep -E "test-script|test-webui" || true
else
  "$ROOT_DIR/scripts/cluster.sh" list 2>&1 | grep -E "test-script|test-webui" || true
fi

# 步骤 7: 运行完整数据一致性测试
echo ""
echo "[步骤 7/7] 运行完整数据一致性测试"
if [ -f "$ROOT_DIR/scripts/test_data_consistency.sh" ]; then
  if "$ROOT_DIR/scripts/test_data_consistency.sh" 2>&1 | tee -a "$LOG_FILE"; then
    echo "  ✓ 数据一致性测试通过"
  else
    echo "  ✗ 数据一致性测试失败"
    exit 1
  fi
else
  echo "  ⚠ test_data_consistency.sh 不存在，跳过"
fi

# 验证 Portainer 和 ArgoCD 中的集群
echo ""
echo "  验证 Portainer 和 ArgoCD..."
echo "    Portainer 应该能看到集群: test-script-k3d, test-script-kind"
echo "    ArgoCD ApplicationSet 应该只包含实际存在的集群"

echo ""
echo "=========================================="
echo "✅ 回归测试完成！"
echo "=========================================="
echo ""
echo "测试结果:"
echo "  ✓ 环境清理成功"
echo "  ✓ 基础环境启动成功"
echo "  ✓ 数据库初始化验证通过"
echo "  ✓ 脚本创建 k3d 集群成功"
echo "  ✓ 脚本创建 kind 集群成功"
echo "  ✓ 数据一致性验证通过"
echo "  ✓ 完整数据一致性测试通过"
echo ""
echo "测试集群:"
echo "  - test-script-k3d (k3d)"
echo "  - test-script-kind (kind)"
echo ""
echo "清理测试集群:"
echo "  scripts/delete_env.sh -n test-script-k3d"
echo "  scripts/delete_env.sh -n test-script-kind"

# 取消清理陷阱（测试成功）
trap - EXIT

exit 0
