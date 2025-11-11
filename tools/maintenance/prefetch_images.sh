#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT_DIR/scripts/lib/lib.sh"

manifest="${1:-}"
if [ -z "$manifest" ]; then
  echo "Usage: $0 <manifest.yaml> [cluster]" >&2
  echo "  e.g. $0 manifests/traefik/traefik.yaml dev" >&2
  exit 1
fi

cluster="${2:-ops}"
load_env
provider="$(provider_for "$cluster")"

# 提取镜像列表（忽略注释行），仅匹配 image: <repo>:<tag>
images=$(grep -E '^\s*image:\s*[^\s]+' "$manifest" | awk '{print $2}' | sort -u)
[ -n "$images" ] || { echo "no images parsed" >&2; exit 1; }

load_kind() {
  local img="$1"
  echo "+ kind load docker-image $img --name $cluster"
  if kind load docker-image "$img" --name "$cluster"; then
    return 0
  fi
  echo "[prefetch] kind load failed; falling back to ctr import..." >&2
  local node="${cluster}-control-plane"
  if ! docker ps --format '{{.Names}}' | grep -qx "$node"; then
    echo "[prefetch] kind node container not found: $node" >&2
    return 1
  fi
  echo "+ docker save $img | docker exec -i $node ctr -n k8s.io images import -"
  docker save "$img" | docker exec -i "$node" ctr -n k8s.io images import -
}

load_k3d() {
  local img="$1"
  # 检查镜像是否已在集群中
  if kubectl --context "k3d-$cluster" get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null | grep -q "^$img$"; then
    echo "[prefetch] image $img already exists in cluster $cluster, skipping import"
    return 0
  fi
  echo "+ k3d image import $img -c $cluster"
  k3d image import "$img" -c "$cluster" || true
}

echo "[prefetch] pulling images for cluster=$cluster provider=$provider ..."
for img in $images; do
  # 检查本地是否已有镜像
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "[prefetch] image $img already exists locally, skipping pull"
  else
    echo "+ docker pull $img"
    docker pull "$img"
  fi

  if [ "$provider" = "kind" ]; then
    load_kind "$img" || true
  else
    load_k3d "$img"
  fi
done

echo "[prefetch] done."

