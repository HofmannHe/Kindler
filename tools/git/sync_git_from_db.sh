#!/usr/bin/env bash
# 根据 DB 记录重建所有 Git 分支
# 用于 Git 操作失败后的修复

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"
GITOPS_LOCK_FILE="${GITOPS_LOCK_FILE:-/tmp/kindler_gitops.lock}"

echo "=========================================="
echo "  从数据库同步 Git 分支（严格 GitOps）"
echo "  - 活跃分支 = 数据库 clusters 表（排除 devops）"
echo "  - 历史分支 → 归档分支（由 GIT_ARCHIVE_PREFIX 控制，默认 archive/）"
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
  echo "  1. WebUI backend container is running" >&2
  echo "  2. SQLite database is accessible" >&2
  exit 1
fi

# 读取 DB 中的集群列表（排除 devops）
echo "[1/4] 读取数据库记录..."
clusters=$(sqlite_query "SELECT name FROM clusters WHERE name != 'devops' ORDER BY name;" 2>/dev/null | grep -v '^$' || echo "")
count=$(echo "$clusters" | grep -c '^' || echo "0")

if [ "$count" -eq 0 ]; then
  echo "  No business clusters found in database"
  exit 0
fi

echo "  Found $count business clusters:"
echo "$clusters" | sed 's/^/    - /'
echo ""

# 为每个集群创建/更新活跃分支
echo "[2/4] 同步活跃分支..."
for cluster in $clusters; do
  echo "  Syncing $cluster..."
  if [ "${DRY_RUN:-}" = "1" ]; then
    echo "    (dry-run) create/update branch: $cluster"
  else
    if "$ROOT_DIR/tools/git/create_git_branch.sh" "$cluster" 2>&1 | sed 's/^/    /'; then
      echo "    ✓ $cluster synced"
    else
      echo "    ✗ $cluster failed"
    fi
  fi
done
echo ""

# 归档策略：将不在数据库中的活跃分支迁移到归档分支并删除原分支
echo "[3/4] 归档无效分支..."
ARCHIVE_PREFIX="${GIT_ARCHIVE_PREFIX:-archive/}"
RESERVED_WORDS="${GIT_RESERVED_BRANCHES:-main master develop release devops}" # 空格分隔的保留分支集合

# 认证 URL
if [ -n "${GIT_PASSWORD:-}" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
else
  GIT_REPO_URL_AUTH="$GIT_REPO_URL"
fi

remote_heads=$(git ls-remote --heads "$GIT_REPO_URL" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' | sort || echo "")
desired_set=$(printf '%s\n' $clusters | sort)
exclude_regex="^($(echo "$RESERVED_WORDS" | tr ' ' '|'))$"

to_archive=$(comm -23 <(echo "$remote_heads" | grep -Ev "$exclude_regex" | grep -Ev "^${ARCHIVE_PREFIX}" | sort) <(echo "$desired_set" | sort) || true)

if [ -z "$to_archive" ]; then
  echo "  ✓ no branches to archive"
else
  if [ "${DRY_RUN:-}" = "1" ]; then
    echo "$to_archive" | sed 's/^/  (dry-run) archive & -> '${ARCHIVE_PREFIX}'&-$(date +%Y%m%d-%H%M%S) and delete original/'
  else
    # Serialize archive operations to avoid concurrent remote updates
    if command -v flock >/dev/null 2>&1; then
      exec 211>"$GITOPS_LOCK_FILE"
      flock -x 211
    fi
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT
    git -c credential.helper= clone --quiet "$GIT_REPO_URL_AUTH" "$TMPDIR/repo" 2>/dev/null || { echo "  ✗ clone failed"; exit 1; }
    cd "$TMPDIR/repo"
    while read -r b; do
      [ -n "$b" ] || continue
      ts=$(date +%Y%m%d-%H%M%S)
      target="${ARCHIVE_PREFIX}${b}-${ts}"
      echo "  Archiving: $b -> $target"
      git fetch origin "$b:$b" >/dev/null 2>&1 || true
      git branch -f "$target" "$b" >/dev/null 2>&1 || git branch "$target" "$b" >/dev/null 2>&1 || true
      git push origin "$target" >/dev/null 2>&1 || echo "    ⚠ push archive failed"
      git push origin ":$b" >/dev/null 2>&1 || echo "    ⚠ delete old branch failed"
    done <<< "$to_archive"
    if command -v flock >/dev/null 2>&1; then
      flock -u 211 2>/dev/null || true
      exec 211>&- 2>/dev/null || true
    fi
  fi
fi

# 验证活跃分支集合 == 数据库集合
echo "[4/4] 验证分支一致性..."
git_branches=$(git ls-remote --heads "$GIT_REPO_URL" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' | grep -v -E "^${ARCHIVE_PREFIX}" | grep -v -E "$exclude_regex" | sort || echo "")
git_count=$(echo "$git_branches" | grep -c '^' || echo "0")

if [ "$git_count" -eq "$count" ]; then
  echo "  ✓ All active branches match database ($git_count/$count)"
  echo ""
  echo "=========================================="
  echo "✅ Git 分支同步完成！"
  echo "=========================================="
  exit 0
else
  echo "  ✗ Active branch set mismatch ($git_count/$count)"
  echo "  DB clusters: $count"
  echo "  Active Git branches: $git_count"
  echo "  Branches:"
  echo "$git_branches" | sed 's/^/    - /'
  exit 1
fi
