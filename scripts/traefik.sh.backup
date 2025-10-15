#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

usage(){ echo "Usage: $0 install <context> [--nodeport <port>]" >&2; exit 1; }
cmd="${1:-}"; ctx="${2:-}"; shift || true; shift || true || true
nodeport=30080
while [ $# -gt 0 ]; do
  case "$1" in
    --nodeport) nodeport="${2:-30080}"; shift 2;;
    *) break;;
  esac
done

case "$cmd" in
  install)
    [ -n "${ctx:-}" ] || usage
    # prefetch image to node to avoid rollout timeout (kind-ops only)
    if docker ps --format '{{.Names}}' | grep -qx "ops-control-plane"; then
      docker pull traefik:v2.10 >/dev/null 2>&1 || true
      docker save traefik:v2.10 | docker exec -i ops-control-plane ctr -n k8s.io images import - >/dev/null 2>&1 || true
    fi
    # apply manifest; override nodePort if needed
    if [ "$nodeport" != "30080" ]; then
      sed "s/nodePort: 30080/nodePort: $nodeport/" "$ROOT_DIR/manifests/traefik/traefik.yaml" | kubectl --context "$ctx" apply --validate=false -f -
    else
      kubectl --context "$ctx" apply --validate=false -f "$ROOT_DIR/manifests/traefik/traefik.yaml"
    fi
    kubectl --context "$ctx" -n traefik rollout status deploy/traefik --timeout=90s || {
      echo "[WARN] traefik not Ready within timeout; continuing" >&2
      kubectl --context "$ctx" -n traefik get pods -o wide || true
    }
    ;;
  *) usage ;;
esac
