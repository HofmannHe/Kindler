#!/usr/bin/env bash
# 根据 DB 记录重建所有 Git 分支
# 用于 Git 操作失败后的修复

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
. "$ROOT_DIR/scripts/lib_db.sh"

echo "=========================================="
echo "  从数据库同步 Git 分支"
echo "=========================================="
echo ""

# 加载配置
load_env
if [ -f "$ROOT_DIR/config/git.env" ]; then
  . "$ROOT_DIR/config/git.env"
fi

if [ -z "${GIT_REPO_URL:-}" ]; then
  echo "[ERROR] GIT_REPO_URL not set in config/git.env" >&2
  exit 1
fi

# 检查数据库可用性
if ! db_is_available 2>/dev/null; then
  echo "[ERROR] Database not available" >&2
  echo "Please ensure:" >&2
  echo "  1. devops cluster is running" >&2
  echo "  2. PostgreSQL Pod is ready" >&2
  exit 1
fi

# 读取 DB 中的集群列表
echo "[1/3] 读取数据库记录..."
clusters=$(db_exec "SELECT name FROM clusters WHERE name != 'devops' ORDER BY name;" | tail -n +3 | head -n -2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
count=$(echo "$clusters" | grep -c '^' || echo "0")

if [ "$count" -eq 0 ]; then
  echo "  No business clusters found in database"
  exit 0
fi

echo "  Found $count business clusters:"
echo "$clusters" | sed 's/^/    - /'
echo ""

# 为每个集群创建 Git 分支
echo "[2/3] 同步 Git 分支..."
for cluster in $clusters; do
  echo "  Syncing $cluster..."
  if "$ROOT_DIR/scripts/create_git_branch.sh" "$cluster" 2>&1 | sed 's/^/    /'; then
    echo "    ✓ $cluster synced"
  else
    echo "    ✗ $cluster failed"
  fi
done
echo ""

# 验证
echo "[3/3] 验证同步结果..."
git_branches=$(git ls-remote --heads "$GIT_REPO_URL" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' | grep -v -E '^(main|develop|release|devops|master)$' | sort || echo "")
git_count=$(echo "$git_branches" | grep -c '^' || echo "0")

if [ "$git_count" -eq "$count" ]; then
  echo "  ✓ All branches synced ($git_count/$count)"
  echo ""
  echo "=========================================="
  echo "✅ Git 分支同步完成！"
  echo "=========================================="
  exit 0
else
  echo "  ✗ Sync incomplete ($git_count/$count)"
  echo "  DB clusters: $count"
  echo "  Git branches: $git_count"
  exit 1
fi

