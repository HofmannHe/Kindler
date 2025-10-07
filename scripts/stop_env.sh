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

echo "[STOP] Stopping environment $name (provider: $provider)"

# 检查集群是否存在
if ! kubectl config get-contexts "$ctx" &>/dev/null; then
  echo "[ERROR] Cluster $name does not exist" >&2
  exit 1
fi

# 停止集群（不删除）
if [ "$provider" = "k3d" ]; then
  echo "[STOP] Stopping k3d cluster..."
  k3d cluster stop "$name" || echo "[WARNING] Failed to stop k3d cluster"
elif [ "$provider" = "kind" ]; then
  echo "[STOP] Stopping kind cluster containers..."
  # kind 没有原生的 stop 命令，需要手动停止容器
  for container in $(docker ps -q --filter "name=$name-control-plane"); do
    docker stop "$container" || echo "[WARNING] Failed to stop container $container"
  done
else
  echo "[ERROR] Unknown provider: $provider" >&2
  exit 2
fi

echo "[DONE] Environment $name stopped (configuration preserved in environments.csv)"
echo "[INFO] To restart: ./scripts/start_env.sh -n $name"
echo "[INFO] To delete permanently: ./scripts/delete_env.sh -n $name"
