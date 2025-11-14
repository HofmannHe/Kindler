#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Validate SQLite clusters schema after migration and ensure baseline rows exist.
# Usage: scripts/test_sqlite_migration.sh
# Category: diagnostics
# Status: stable
# See also: scripts/db_verify.sh, scripts/test_data_consistency.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

echo "=========================================="
echo "  SQLite 迁移验证 (test_sqlite_migration.sh)"
echo "=========================================="

if ! sqlite_is_available > /dev/null 2>&1; then
  echo "✗ 无法访问 SQLite 数据库 (kindler-webui-backend 未运行?)" >&2
  exit 1
fi

echo "✓ SQLite 数据库可访问"

schema=$(sqlite_query "PRAGMA table_info(clusters);" 2> /dev/null || true)
if [ -z "$schema" ]; then
  echo "✗ 未找到 clusters 表" >&2
  exit 1
fi

required_cols=(name provider node_port pf_port http_port https_port desired_state actual_state last_reconciled_at)
missing_cols=()
for col in "${required_cols[@]}"; do
  if ! printf '%s\n' "$schema" | awk -F'|' '{print $2}' | grep -qx "$col"; then
    missing_cols+=("$col")
  fi
done

if [ "${#missing_cols[@]}" -gt 0 ]; then
  echo "✗ clusters 表缺少字段: ${missing_cols[*]}" >&2
  exit 1
fi

echo "✓ clusters 表字段齐全"

devops_count=$(sqlite_query "SELECT COUNT(*) FROM clusters WHERE name='devops';" 2> /dev/null | tr -d ' \n' || echo "0")
if [ "${devops_count:-0}" -eq 0 ]; then
  echo "✗ clusters 表中缺少 devops 记录" >&2
  exit 1
fi
echo "✓ devops 集群记录存在"

total_clusters=$(sqlite_query "SELECT COUNT(*) FROM clusters;" 2> /dev/null | tr -d ' \n' || echo "0")
echo "✓ 当前 clusters 记录数: ${total_clusters}"

echo "=========================================="
echo "✅ SQLite 迁移校验通过"
echo "=========================================="
exit 0
