#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Delete a business cluster and clean HAProxy/Portainer/ArgoCD/Git registrations.
# Usage: scripts/delete_env.sh -n <name> [-p kind|k3d]
# See also: scripts/create_env.sh, scripts/haproxy_route.sh, scripts/argocd_register.sh, scripts/portainer.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

usage() { echo "Usage: $0 -n <name> [-p kind|k3d]" >&2; exit 1; }

name=""; provider=""
while getopts ":n:p:" opt; do
  case "$opt" in
    n) name="$OPTARG" ;;
    p) provider="$OPTARG" ;;
    *) usage ;;
  esac
done
[ -z "$name" ] && usage
if [ -z "$provider" ]; then
  load_env
  provider="$(provider_for "$name")"
fi
ctx_prefix=$([ "$provider" = "k3d" ] && echo k3d || echo kind)
ctx="$ctx_prefix-$name"

# 清理 Edge Agent Kubernetes 资源（在删除集群之前）
echo "[DELETE] Edge Agent from cluster $name"
kubectl --context "$ctx" delete namespace portainer-edge --ignore-not-found=true --timeout=30s 2>/dev/null || true

echo "[DELETE] haproxy route for $name"
"$ROOT_DIR"/scripts/haproxy_route.sh remove "$name" || true

# delete Portainer Edge Environment (使用与 register_edge_agent.sh 相同的命名规则)
# 移除连字符，例如 dev-k3d -> devk3d
ep_name=$(echo "$name" | sed 's/-//g')
echo "[DELETE] Portainer Edge Environment: $ep_name"
"$ROOT_DIR"/scripts/portainer.sh del-endpoint "$ep_name" || true

# Unregister from ArgoCD
echo "[DELETE] Unregistering cluster from ArgoCD..."
"$ROOT_DIR"/scripts/argocd_register.sh unregister "$name" "$provider" || echo "[WARNING] Failed to unregister from ArgoCD"

# 删除 Git 分支
echo "[DELETE] Removing Git branch for $name..."
if [ -f "$ROOT_DIR/tools/git/delete_git_branch.sh" ]; then
  if "$ROOT_DIR/tools/git/delete_git_branch.sh" "$name" 2>&1 | sed 's/^/  /'; then
    echo "[DELETE] ✓ Git branch removed"
  else
    echo "[WARN] Git branch deletion failed (will continue)"
    echo "[WARN] You can manually delete it with:"
    echo "       tools/git/delete_git_branch.sh $name"
  fi
else
  echo "[WARN] tools/git/delete_git_branch.sh not found, skipping Git branch deletion"
fi

# 从数据库中删除集群记录（优先）
if db_is_available 2>/dev/null; then
  echo "[DELETE] Removing cluster configuration from database..."
  if db_delete_cluster "$name"; then
    echo "[DELETE] ✓ Cluster configuration removed from database"
  else
    echo "[WARN] Failed to remove cluster configuration from database"
  fi
else
  echo "[INFO] Database not available, skipping database cleanup"
fi

# 从 CSV 配置文件中移除环境配置（已废弃 - 使用数据库作为唯一数据源）
# CSV_FILE="$ROOT_DIR/config/environments.csv"
# if [ -f "$CSV_FILE" ]; then
#   echo "[DELETE] Removing $name from environments.csv..."
#   tmp_file=$(mktemp)
#   awk -F, -v env="$name" '$1 != env' "$CSV_FILE" > "$tmp_file"
#   mv "$tmp_file" "$CSV_FILE"
#   echo "[SUCCESS] Environment $name removed from CSV"
# else
#   echo "[WARNING] environments.csv not found, skipping CSV cleanup"
# fi
echo "[INFO] CSV cleanup skipped (using database as single source of truth)"

# 同步 ApplicationSet（自动移除已删除环境的 whoami 应用）
echo "[DELETE] Syncing ApplicationSet for whoami..."
"$ROOT_DIR"/scripts/sync_applicationset.sh || echo "[WARNING] Failed to sync ApplicationSet"

echo "[DELETE] cluster $name via $provider"
PROVIDER="$provider" "$ROOT_DIR"/scripts/cluster.sh delete "$name" || true

echo "[DONE] Deleted env $name (cluster + configuration)"
echo "[INFO] Environment $name has been permanently deleted"
