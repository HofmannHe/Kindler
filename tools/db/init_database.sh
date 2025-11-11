#!/usr/bin/env bash
# 初始化 SQLite 数据库表结构

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

echo "=========================================="
echo "  初始化 SQLite 数据库表结构"
echo "=========================================="
echo ""

echo "[DB] 检查数据库可用性..."
if ! sqlite_is_available; then
  echo "[ERROR] SQLite 数据库不可用"
  echo "[INFO] 请确保 WebUI 后端容器正在运行：docker ps | grep kindler-webui-backend"
  exit 1
fi

echo "[DB] 初始化表结构..."
# lib_sqlite.sh 会自动初始化表结构，这里只是验证
if sqlite_query "SELECT name FROM sqlite_master WHERE type='table' AND name='clusters';" 2>/dev/null | grep -q "clusters"; then
  echo "✓ clusters 表已存在"
else
  echo "[ERROR] clusters 表未创建"
  exit 1
fi

echo ""
echo "[DB] 验证表结构..."
sqlite_query "PRAGMA table_info(clusters);" | head -15

echo ""
echo "[DB] 验证 server_ip 列存在..."
if sqlite_query "PRAGMA table_info(clusters);" 2>/dev/null | grep -q "server_ip"; then
  echo "✓ server_ip 列存在"
else
  echo "[ERROR] server_ip column not found in clusters table!"
  exit 1
fi

echo ""
echo "=========================================="
echo "✅ SQLite 数据库初始化完成！"
echo "=========================================="
echo ""
echo "验证："
echo "  sqlite_query \"SELECT * FROM clusters;\""

