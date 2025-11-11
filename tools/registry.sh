#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
  cat >&2 <<USAGE
Usage: $0 <up|down|status|seed|config-k3d> [cluster]

Commands:
  up                Start local Docker registry (registry:2) on :5000
  down              Stop and remove local registry container/volume (keep data volume by default)
  status            Show registry container and endpoint info
  seed              Pull a few base images and push into localhost:5000
  config-k3d <c>    Configure k3d <c> cluster to use host.k3d.internal:5000 as docker.io mirror

Notes:
  - k3d nodes can reach host registry via host.k3d.internal:5000
  - This writes /etc/rancher/k3s/registries.yaml inside the server node and restarts it
USAGE
  exit 1
}

ensure_registry() {
  docker ps --format '{{.Names}}' | grep -qx 'local-registry' && return 0
  docker inspect local-registry >/dev/null 2>&1 && {
    docker start local-registry >/dev/null
    return 0
  }
  docker run -d --restart=unless-stopped --name local-registry \
    -p 5000:5000 -v registry_data:/var/lib/registry registry:2 >/dev/null
}

cmd="${1:-}"; arg="${2:-}"; [ -n "$cmd" ] || usage

case "$cmd" in
  up)
    ensure_registry
    echo "[registry] up at http://127.0.0.1:5000"
    ;;
  down)
    docker rm -f local-registry >/dev/null 2>&1 || true
    # keep data volume to preserve cache; uncomment to clear
    # docker volume rm registry_data >/dev/null 2>&1 || true
    echo "[registry] down"
    ;;
  status)
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' | sed -n '1,50p'
    ;;
  seed)
    ensure_registry
    imgs=(traefik/whoami:latest nginx:alpine library/traefik:v2.10)
    for img in "${imgs[@]}"; do
      docker pull "$img" >/dev/null 2>&1 || true
      dst="localhost:5000/${img}"
      docker tag "$img" "$dst" && docker push "$dst" >/dev/null 2>&1 || true
      echo "[seed] pushed $dst"
    done
    ;;
  config-k3d)
    [ -n "$arg" ] || { echo "cluster name required" >&2; exit 2; }
    ensure_registry
    node="k3d-${arg}-server-0"
    if ! docker inspect "$node" >/dev/null 2>&1; then
      echo "[registry] cluster node not found: $node" >&2
      exit 3
    fi
    tmp=$(mktemp)
    # use docker network gateway IP for k3d-shared (default 10.100.0.1)
    gw_ip="10.100.0.1"
    cat >"$tmp" <<YAML
mirrors:
  "docker.io":
    endpoint:
      - "http://${gw_ip}:5000"
configs:
  "${gw_ip}:5000":
    tls:
      insecure_skip_verify: true
YAML
    docker cp "$tmp" "$node:/etc/rancher/k3s/registries.yaml"
    rm -f "$tmp"
    echo "[registry] restarting node to load registries.yaml"
    docker restart "$node" >/dev/null
    echo "[registry] waiting for CoreDNS..."
    kubectl --context "k3d-${arg}" wait -n kube-system --for=condition=ready pod -l k8s-app=kube-dns --timeout=120s >/dev/null || true
    echo "[registry] k3d-$arg configured"
    ;;
  *) usage ;;
esac

