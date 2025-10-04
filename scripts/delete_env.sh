#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

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

echo "[DELETE] cluster $name via $provider"
PROVIDER="$provider" "$ROOT_DIR"/scripts/cluster.sh delete "$name" || true

echo "[DONE] Deleted env $name"
