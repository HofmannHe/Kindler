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

echo "[START] Starting environment $name (provider: $provider)"

# 检查集群配置是否存在于 kubeconfig
if ! kubectl config get-contexts "$ctx" &>/dev/null; then
  echo "[ERROR] Cluster $name context not found in kubeconfig" >&2
  echo "[INFO] The cluster may have been deleted. Use create_env.sh to recreate it." >&2
  exit 1
fi

# 启动集群
if [ "$provider" = "k3d" ]; then
  echo "[START] Starting k3d cluster..."
  if k3d cluster start "$name"; then
    echo "[SUCCESS] k3d cluster $name started"
  else
    echo "[ERROR] Failed to start k3d cluster $name" >&2
    exit 3
  fi
elif [ "$provider" = "kind" ]; then
  echo "[START] Starting kind cluster containers..."
  # kind 需要手动启动容器
  started=0
  for container in $(docker ps -aq --filter "name=$name-control-plane"); do
    if docker start "$container"; then
      echo "[SUCCESS] Started container $container"
      started=1
    else
      echo "[WARNING] Failed to start container $container"
    fi
  done
  if [ $started -eq 0 ]; then
    echo "[ERROR] No kind cluster containers found for $name" >&2
    exit 4
  fi
else
  echo "[ERROR] Unknown provider: $provider" >&2
  exit 2
fi

# 等待集群就绪
echo "[START] Waiting for cluster to be ready..."
if kubectl --context "$ctx" wait --for=condition=ready node --all --timeout=60s 2>/dev/null; then
  echo "[SUCCESS] Cluster $name is ready"
else
  echo "[WARNING] Cluster may not be fully ready yet"
fi

echo "[DONE] Environment $name started"
echo "[INFO] Verify with: kubectl --context $ctx get nodes"
