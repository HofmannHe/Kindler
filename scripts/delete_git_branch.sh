#!/usr/bin/env bash
# 删除单个集群的 Git 分支

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 加载配置
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
fi

GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_USERNAME="${GIT_USERNAME:-codex}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

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

echo "[GIT] Deleting branch: $CLUSTER_NAME"

# 检查分支是否存在
if ! git ls-remote --heads "$GIT_REPO_URL" "$CLUSTER_NAME" 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "  ⚠ Branch '$CLUSTER_NAME' does not exist (already deleted or never created)"
  exit 0
fi

# 删除分支
if [ -n "$GIT_PASSWORD" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
else
  GIT_REPO_URL_AUTH="$GIT_REPO_URL"
fi

if git push "$GIT_REPO_URL_AUTH" --delete "$CLUSTER_NAME" 2>&1 | grep -v "password"; then
  echo "  ✓ Branch '$CLUSTER_NAME' deleted"
  exit 0
else
  echo "  ✗ Failed to delete branch '$CLUSTER_NAME'"
  echo "  Manual cleanup: git push $GIT_REPO_URL --delete $CLUSTER_NAME"
  exit 1
fi


