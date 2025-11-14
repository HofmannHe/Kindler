#!/usr/bin/env bash
# 删除单个集群的 Git 分支

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# 加载配置
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
fi

GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_USERNAME="${GIT_USERNAME:-codex}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

git_push_with_retry() {
  local remote="$1"
  shift
  local tries=0 max=5 delay=2 rc=0
  while [ $tries -lt $max ]; do
    tries=$((tries + 1))
    if [ -n "$GIT_PASSWORD" ]; then
      git push "$remote" "$@" 2>&1 | grep -v "password" || true
      rc=${PIPESTATUS[0]}
    else
      git push "$remote" "$@" || true
      rc=$?
    fi
    if [ $rc -eq 0 ]; then
      return 0
    fi
    echo "[GIT] push failed (attempt $tries/$max, rc=$rc); retrying in $((delay * tries))s..." >&2
    sleep $((delay * tries))
  done
  return $rc
}

usage() {
  echo "Usage: $0 <cluster-name>" >&2
  echo "Example: $0 dev" >&2
  exit 1
}

if [ $# -ne 1 ]; then
  usage
fi

CLUSTER_NAME="$1"

if [ -z "$GIT_REPO_URL" ]; then
  echo "[WARN] GIT_REPO_URL not set in config/git.env" >&2
  echo "  Skipping Git branch deletion" >&2
  exit 0
fi

# 判断分支类型
get_branch_type() {
  local name="$1"
  case "$name" in
    devops|main|master) echo "protected" ;;
    dev|uat|prod) echo "long-lived" ;;
    test-*) echo "ephemeral" ;;
    *) echo "unknown" ;;
  esac
}

BRANCH_TYPE=$(get_branch_type "$CLUSTER_NAME")
echo "[GIT] Branch type: $BRANCH_TYPE"

# 检查分支是否存在
if ! git ls-remote --heads "$GIT_REPO_URL" "$CLUSTER_NAME" 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "  ⚠ Branch '$CLUSTER_NAME' does not exist (already deleted or never created)"
  exit 0
fi

# 配置认证
if [ -n "$GIT_PASSWORD" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
else
  GIT_REPO_URL_AUTH="$GIT_REPO_URL"
fi
PUSH_REMOTE="$GIT_REPO_URL_AUTH"

# 根据分支类型处理
case "$BRANCH_TYPE" in
  protected)
    echo "  ✗ Cannot delete protected branch: $CLUSTER_NAME"
    exit 1
    ;;

  long-lived)
    echo "  ⚠ Deleting long-lived branch: $CLUSTER_NAME"
    echo "  Creating archive tag..."

    # 创建临时目录
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT
    cd "$TMPDIR"

    # Clone并创建tag
    if git clone --quiet "$GIT_REPO_URL_AUTH" repo 2>&1 | grep -v "password"; then
      cd repo
      git fetch origin "$CLUSTER_NAME:$CLUSTER_NAME" 2>/dev/null || true
      
      local timestamp=$(date +%Y%m%d-%H%M%S)
      local tag_name="archive/$CLUSTER_NAME/$timestamp"
      
      if git tag "$tag_name" "$CLUSTER_NAME" -m "Archive before deletion at $timestamp" 2>/dev/null; then
        if git_push_with_retry "$GIT_REPO_URL_AUTH" "$tag_name"; then
          echo "  ✓ Archive tag created: $tag_name"
        else
          echo "  ✗ Failed to push archive tag"
          exit 1
        fi
      else
        echo "  ⚠ Failed to create archive tag"
      fi
    else
      echo "  ⚠ Failed to clone for archiving"
    fi

    # 删除分支
    if git_push_with_retry "$PUSH_REMOTE" --delete "$CLUSTER_NAME"; then
      echo "  ✓ Branch deleted (archive preserved)"
      exit 0
    else
      echo "  ✗ Branch deletion failed"
      exit 1
    fi
    ;;

  ephemeral)
    # test-api-* 保留供查看，test-e2e-* 直接删除
    if [[ "$CLUSTER_NAME" =~ ^test-api- ]]; then
      echo "  ℹ Preserving test-api branch for inspection: $CLUSTER_NAME"
      exit 0
    fi
    
    echo "  ✓ Deleting ephemeral branch: $CLUSTER_NAME"
    if git_push_with_retry "$PUSH_REMOTE" --delete "$CLUSTER_NAME"; then
      echo "  ✓ Branch deleted"
      exit 0
    else
      echo "  ✗ Branch deletion failed"
      exit 1
    fi
    ;;

  unknown)
    echo "  ⚠ Unknown branch type, deleting without archive: $CLUSTER_NAME"
    if git_push_with_retry "$PUSH_REMOTE" --delete "$CLUSTER_NAME"; then
      echo "  ✓ Branch deleted"
      exit 0
    else
      echo "  ✗ Branch deletion failed"
      exit 1
    fi
    ;;
esac
