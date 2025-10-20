#!/usr/bin/env bash
# 清理 Git 中不在 DB 的业务分支
# 保留 main/develop/release/devops 分支

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
. "$ROOT_DIR/scripts/lib_db.sh"

echo "=========================================="
echo "  清理孤立 Git 分支"
echo "=========================================="
echo ""

# 加载配置
load_env
if [ -f "$ROOT_DIR/config/git.env" ]; then
  . "$ROOT_DIR/config/git.env"
fi

GIT_USERNAME="${GIT_USERNAME:-codex}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

if [ -z "${GIT_REPO_URL:-}" ]; then
  echo "[ERROR] GIT_REPO_URL not set in config/git.env" >&2
  exit 1
fi

# 读取 DB 中的集群列表
echo "[1/3] 读取数据库记录..."
if db_is_available 2>/dev/null; then
  db_clusters=$(db_exec "SELECT name FROM clusters ORDER BY name;" | tail -n +3 | head -n -2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo "  ✓ DB: $(echo "$db_clusters" | grep -c '^' || echo "0") clusters"
else
  echo "  ⚠ DB not available, using CSV"
  db_clusters=$(awk -F, 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv")
fi
echo ""

# 列出所有 Git 分支
echo "[2/3] 检查 Git 分支..."
git_branches=$(git ls-remote --heads "$GIT_REPO_URL" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' | sort || echo "")
business_branches=$(echo "$git_branches" | grep -v -E '^(main|develop|release|devops|master)$' || echo "")

if [ -z "$business_branches" ]; then
  echo "  No business branches found"
  exit 0
fi

echo "  Found $(echo "$business_branches" | grep -c '^' || echo "0") business branches"
echo ""

# 查找孤立分支
orphaned=""
for branch in $business_branches; do
  if ! echo "$db_clusters" | grep -q "^${branch}$"; then
    orphaned="${orphaned}${branch}"$'\n'
    echo "  ✗ Orphaned: $branch (not in DB)"
  fi
done

orphaned=$(echo "$orphaned" | grep -v '^$' || echo "")
orphaned_count=$(echo "$orphaned" | grep -c '^' || echo "0")

if [ "$orphaned_count" -eq 0 ]; then
  echo "  ✓ No orphaned branches found"
  exit 0
fi

echo ""
echo "[3/3] 删除孤立分支..."
echo "  Found $orphaned_count orphaned branches"
echo ""
echo "  Branches to delete:"
echo "$orphaned" | sed 's/^/    - /'
echo ""

read -p "Delete these branches? (y/N) " -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "  Aborted"
  exit 0
fi

# 删除分支
if [ -n "$GIT_PASSWORD" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
else
  GIT_REPO_URL_AUTH="$GIT_REPO_URL"
fi

deleted=0
failed=0

for branch in $orphaned; do
  echo "  Deleting $branch..."
  if git push "$GIT_REPO_URL_AUTH" --delete "$branch" 2>&1 | grep -v "password" >/dev/null; then
    echo "    ✓ Deleted"
    deleted=$((deleted + 1))
  else
    echo "    ✗ Failed"
    failed=$((failed + 1))
  fi
done

echo ""
echo "=========================================="
echo "  完成"
echo "=========================================="
echo "  Deleted: $deleted"
echo "  Failed: $failed"
echo ""

if [ "$failed" -eq 0 ]; then
  echo "✅ All orphaned branches cleaned!"
  exit 0
else
  echo "⚠️ Some branches failed to delete"
  exit 1
fi


