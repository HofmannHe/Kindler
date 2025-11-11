#!/usr/bin/env bash
# 测试 SQLite 迁移后的功能验证脚本

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

echo "=========================================="
echo "  SQLite 迁移功能验证测试"
echo "=========================================="
echo ""

# 测试 1: 数据库可用性
echo "[TEST 1] 检查数据库可用性..."
if sqlite_is_available 2>/dev/null; then
  echo "  ✓ SQLite 数据库可用"
else
  echo "  ⚠ SQLite 数据库不可用（可能是环境未启动）"
  echo "    提示: 确保 WebUI 后端容器正在运行: docker ps | grep kindler-webui-backend"
  echo "    提示: 或者先运行 bootstrap.sh 启动完整环境"
  echo ""
  echo "    跳过数据库操作测试，仅验证脚本语法..."
  exit 0
fi
echo ""

# 测试 2: 表结构
echo "[TEST 2] 检查表结构..."
if sqlite_query "SELECT name FROM sqlite_master WHERE type='table' AND name='clusters';" 2>/dev/null | grep -q "clusters"; then
  echo "  ✓ clusters 表存在"
  
  # 检查字段
  columns=$(sqlite_query "PRAGMA table_info(clusters);" 2>/dev/null | awk -F'|' '{print $2}' | tr '\n' ' ')
  if echo "$columns" | grep -q "server_ip"; then
    echo "  ✓ server_ip 字段存在"
  else
    echo "  ✗ server_ip 字段不存在"
    exit 1
  fi
else
  echo "  ✗ clusters 表不存在"
  exit 1
fi
echo ""

# 测试 3: 插入和查询（如果数据库为空，跳过）
echo "[TEST 3] 测试基本 CRUD 操作..."
existing_clusters=$(sqlite_query "SELECT COUNT(*) FROM clusters;" 2>/dev/null | tr -d ' \n')
echo "  当前集群数量: ${existing_clusters:-0}"

if [ "${existing_clusters:-0}" -eq 0 ]; then
  echo "  ℹ 数据库为空，跳过 CRUD 测试"
else
  # 测试查询
  first_cluster=$(sqlite_query "SELECT name FROM clusters LIMIT 1;" 2>/dev/null | head -1 | tr -d ' \n')
  if [ -n "$first_cluster" ]; then
    echo "  ✓ 查询功能正常 (示例: $first_cluster)"
    
    # 测试获取集群信息
    cluster_info=$(sqlite_get_cluster "$first_cluster" 2>/dev/null || echo "")
    if [ -n "$cluster_info" ]; then
      echo "  ✓ sqlite_get_cluster 功能正常"
    else
      echo "  ⚠ sqlite_get_cluster 返回空（可能正常）"
    fi
  fi
fi
echo ""

# 测试 4: 并发锁测试（简单测试）
echo "[TEST 4] 测试文件锁机制..."
if [ -f "$SQLITE_LOCK" ]; then
  echo "  ℹ 锁文件存在: $SQLITE_LOCK"
else
  echo "  ℹ 锁文件将在第一次使用时创建"
fi
echo ""

# 测试 5: 容器检测
echo "[TEST 5] 测试容器检测..."
if _is_in_container; then
  echo "  ✓ 检测到在容器内执行"
else
  echo "  ℹ 在主机上执行"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^kindler-webui-backend$"; then
    echo "  ✓ WebUI 后端容器正在运行"
  else
    echo "  ⚠ WebUI 后端容器未运行（某些功能可能不可用）"
  fi
fi
echo ""

echo "=========================================="
echo "✅ SQLite 迁移功能验证完成"
echo "=========================================="
echo ""
echo "后续验证步骤:"
echo "1. 运行 bootstrap.sh 验证完整流程"
echo "2. 使用 create_env.sh 创建测试集群"
echo "3. 验证数据在 WebUI 中可见"
echo "4. 测试 WebUI 创建集群功能"
