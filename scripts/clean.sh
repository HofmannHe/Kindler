#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

echo "[CLEAN] Killing port-forwards..."
pgrep -af "kubectl.*port-forward" | awk '{print $1}' | xargs -r kill -9 || true

echo "[CLEAN] Stopping infrastructure (Portainer + HAProxy + Gitea)..."
docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" down -v || true

echo "[CLEAN] Force stopping Portainer containers..."
docker stop portainer-ce >/dev/null 2>&1 || true
docker rm portainer-ce >/dev/null 2>&1 || true

echo "[CLEAN] Removing Portainer named volumes..."
docker volume rm infrastructure_portainer_data >/dev/null 2>&1 || true
docker volume rm infrastructure_haproxy_certs >/dev/null 2>&1 || true
docker volume rm portainer_portainer_data >/dev/null 2>&1 || true
docker volume rm portainer_secrets >/dev/null 2>&1 || true

echo "[CLEAN] Cleaning Portainer Edge agents from clusters..."
for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -E '^k3d-|^kind-'); do
  kubectl --context="$ctx" delete namespace portainer-edge --ignore-not-found=true --timeout=10s >/dev/null 2>&1 || true
done

echo "[CLEAN] Deleting clusters (from CSV and defaults)..."
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi

delete_one() {
  local n="$1" p="$2"
  case "$p" in
    k3d) k3d cluster delete "$n" >/dev/null 2>&1 || true ;;
    *)   kind delete cluster --name "$n" >/dev/null 2>&1 || true ;;
  esac
}

# from CSV if present
if [ -f "$ROOT_DIR/config/environments.csv" ]; then
  awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1","$2}' "$ROOT_DIR/config/environments.csv" | while IFS=, read -r n p; do
    [ -n "$n" ] || continue
    [ -n "$p" ] || p=kind
    delete_one "$n" "$p"
  done
fi

# also attempt defaults
for n in dev uat prod ops; do
  up="$(echo "$n" | tr '[:lower:]' '[:upper:]')"
  pvar="PROVIDER_${up}"; nvar="CLUSTER_${up}"
  provider="${!pvar:-kind}"; name="${!nvar:-$n}"
  delete_one "$name" "$provider"
done

# Delete devops management cluster
echo "[CLEAN] Deleting devops management cluster..."
k3d cluster delete devops 2>&1 || true

# Force cleanup any remaining k3d/kind clusters
echo "[CLEAN] Force cleanup remaining clusters..."
k3d cluster list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null | while read -r cluster; do
  [ -n "$cluster" ] && k3d cluster delete "$cluster" 2>&1 || true
done
kind get clusters 2>/dev/null | while read -r cluster; do
  [ -n "$cluster" ] && kind delete cluster --name "$cluster" 2>&1 || true
done

echo "[CLEAN] Removing generated data and Gitea token..."
rm -rf "$ROOT_DIR/data" || true
rm -f "$ROOT_DIR/.gitea_token" || true
mkdir -p "$ROOT_DIR/data"

echo "[CLEAN] Disconnecting Portainer from K3D networks..."
for net in $(docker network ls --format '{{.Name}}' | grep '^k3d-'); do
  docker network disconnect "$net" portainer-ce 2>/dev/null || true
done

echo "[CLEAN] Removing infrastructure network..."
docker network rm infrastructure >/dev/null 2>&1 || true

echo "[CLEAN] Done."

