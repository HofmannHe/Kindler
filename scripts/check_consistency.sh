#!/usr/bin/env bash
# 检查 DB、Git、K8s 三者一致性
# 输出不一致项和修复建议

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

echo "=========================================="
echo "  一致性检查 (DB / Git / K8s)"
echo "=========================================="
echo ""

# 加载配置
load_env
. "$ROOT_DIR/config/git.env"

inconsistencies=0

# 1. 从 DB 读取集群列表
echo "[1/5] 读取数据库记录..."
if db_is_available 2>/dev/null; then
  db_clusters=$(sqlite_query "SELECT name FROM clusters ORDER BY name;" 2>/dev/null | grep -v '^$' || echo "")
  db_count=$(echo "$db_clusters" | grep -c '^' || echo "0")
  echo "  ✓ DB: $db_count clusters"
  echo "$db_clusters" | sed 's/^/    - /'
else
  echo "  ✗ DB: Not available (using CSV fallback)"
  db_clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv")
  db_count=$(echo "$db_clusters" | grep -c '^' || echo "0")
  echo "  ⚠ CSV: $db_count clusters"
fi
echo ""

# 2. 检查 Git 分支
echo "[2/5] 检查 Git 分支..."
if [ -n "${GIT_REPO_URL:-}" ]; then
  git_branches=$(git ls-remote --heads "$GIT_REPO_URL" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' | grep -v -E '^(main|develop|release|devops|master)$' | sort || echo "")
  git_count=$(echo "$git_branches" | grep -c '^' || echo "0")
  echo "  ✓ Git: $git_count branches"
  echo "$git_branches" | sed 's/^/    - /'
else
  echo "  ✗ Git: GIT_REPO_URL not set"
  git_branches=""
  git_count=0
fi
echo ""

# 3. 检查 K8s 集群
echo "[3/5] 检查 Kubernetes 集群..."
k8s_clusters=""
for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -E '^(k3d-|kind-)' | sed 's/^k3d-//;s/^kind-//' | grep -v '^devops$' | sort); do
  k8s_clusters="${k8s_clusters}${ctx}"$'\n'
done
k8s_clusters=$(echo "$k8s_clusters" | grep -v '^$' || echo "")
k8s_count=$(echo "$k8s_clusters" | grep -c '^' || echo "0")
echo "  ✓ K8s: $k8s_count clusters"
echo "$k8s_clusters" | sed 's/^/    - /'
echo ""

# 4. 一致性分析
echo "[4/5] 一致性分析..."

# DB 有但 Git 无
echo "$db_clusters" | while read -r cluster; do
  [ -z "$cluster" ] && continue
  if ! echo "$git_branches" | grep -q "^${cluster}$"; then
    echo "  ✗ Cluster '$cluster' in DB but Git branch missing"
    inconsistencies=$((inconsistencies + 1))
  fi
done

# Git 有但 DB 无
echo "$git_branches" | while read -r branch; do
  [ -z "$branch" ] && continue
  if ! echo "$db_clusters" | grep -q "^${branch}$"; then
    echo "  ✗ Git branch '$branch' exists but not in DB"
    inconsistencies=$((inconsistencies + 1))
  fi
done

# DB 有但 K8s 无
echo "$db_clusters" | while read -r cluster; do
  [ -z "$cluster" ] && continue
  if ! echo "$k8s_clusters" | grep -q "^${cluster}$"; then
    echo "  ✗ Cluster '$cluster' in DB but K8s cluster missing"
    inconsistencies=$((inconsistencies + 1))
  fi
done

# K8s 有但 DB 无
echo "$k8s_clusters" | while read -r cluster; do
  [ -z "$cluster" ] && continue
  if ! echo "$db_clusters" | grep -q "^${cluster}$"; then
    echo "  ✗ K8s cluster '$cluster' exists but not in DB"
    inconsistencies=$((inconsistencies + 1))
  fi
done

if [ "$inconsistencies" -eq 0 ]; then
  echo "  ✓ All resources consistent"
fi
echo ""

# 5. 修复建议
echo "[5/5] 修复建议..."
if [ "$inconsistencies" -gt 0 ]; then
  echo "  Found $inconsistencies inconsistencies"
  echo ""
  echo "  Suggested fixes:"
  echo "    - Sync Git from DB: tools/git/sync_git_from_db.sh"
  echo "    - Clean orphaned Git branches: tools/maintenance/cleanup_orphaned_branches.sh"
  echo "    - Clean orphaned K8s clusters: tools/maintenance/cleanup_orphaned_clusters.sh"
  exit 1
else
  echo "  ✓ No action needed"
  echo ""
  echo "=========================================="
  echo "✅ All resources are consistent!"
  echo "=========================================="
  exit 0
fi
