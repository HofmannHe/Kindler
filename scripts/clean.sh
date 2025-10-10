#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "[DRY-RUN][CLEAN] 将执行:"
  echo "  - 终止 kubectl port-forward"
  echo "  - 停止并移除 Portainer/HAProxy (compose) 与命名卷"
  echo "  - 移除各集群中的 Edge Agent 命名空间"
  echo "  - 删除 CSV/默认集群与 devops 管理集群"
  echo "  - 清理遗留 k3d/kind 集群、数据目录、网络连接/网络"
  echo "  - 清理 Portainer Endpoint（避免重名）"
  echo "  - 重置 haproxy.cfg 动态路由区块"
  echo "  - 清理 kubeconfig 中的相关 context/cluster"
  exit 0
fi

echo "[CLEAN] Killing port-forwards..."
pgrep -af "kubectl.*port-forward" | awk '{print $1}' | xargs -r kill -9 || true

echo "[CLEAN] Trying to delete Portainer endpoints (idempotent)..."
# 在停止 Portainer 前，尽力通过 API 删除可能残留的 Edge 端点，避免后续重名
if docker ps --format '{{.Names}}' | grep -q '^portainer-ce$'; then
  if [ -f "$ROOT_DIR/config/environments.csv" ]; then
    awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" | while read -r env; do
      [ -n "$env" ] || continue
      ep=$(echo "$env" | tr -d '-')
      "$ROOT_DIR/scripts/portainer.sh" del-endpoint "$ep" >/dev/null 2>&1 || true
    done
  fi
  # 额外清理 devops 端点
  "$ROOT_DIR/scripts/portainer.sh" del-endpoint devops >/dev/null 2>&1 || true
fi

echo "[CLEAN] Stopping infrastructure (Portainer + HAProxy)..."
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

echo "[CLEAN] Reset haproxy.cfg dynamic sections..."
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
if [ -f "$CFG" ]; then
  tmp=$(mktemp)
  awk '
    BEGIN{in_dyn_acl=0; in_dyn_be=0}
    {
      if ($0 ~ /# BEGIN DYNAMIC ACL/) {print $0; in_dyn_acl=1; next}
      if (in_dyn_acl && $0 ~ /# END DYNAMIC ACL/) {print $0; in_dyn_acl=0; next}
      if (in_dyn_acl) {next}
      if ($0 ~ /# BEGIN DYNAMIC BACKENDS/) {print $0; in_dyn_be=1; next}
      if (in_dyn_be) {
        if ($0 ~ /^backend be_portainer_https/) {in_dyn_be=0}
        else {next}
      }
      print $0
    }
  ' "$CFG" >"$tmp" && mv "$tmp" "$CFG" || true
fi

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

echo "[CLEAN] Cleanup related kubeconfig contexts/clusters..."
if command -v kubectl >/dev/null 2>&1; then
  # From CSV
  if [ -f "$ROOT_DIR/config/environments.csv" ]; then
    awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1","$2}' "$ROOT_DIR/config/environments.csv" | while IFS=, read -r n p; do
      [ -n "$n" ] || continue
      [ -n "$p" ] || p=kind
      if [ "$p" = "k3d" ]; then
        kubectl config delete-context "k3d-$n" >/dev/null 2>&1 || true
        kubectl config delete-cluster "k3d-$n" >/dev/null 2>&1 || true
        kubectl config unset "users.k3d-$n" >/dev/null 2>&1 || true
      else
        kubectl config delete-context "kind-$n" >/dev/null 2>&1 || true
        kubectl config delete-cluster "kind-$n" >/dev/null 2>&1 || true
      fi
    done
  fi
  # Defaults + devops
  for n in dev uat prod ops; do
    kubectl config delete-context "k3d-$n" >/dev/null 2>&1 || true
    kubectl config delete-context "kind-$n" >/dev/null 2>&1 || true
    kubectl config delete-cluster "k3d-$n" >/dev/null 2>&1 || true
    kubectl config delete-cluster "kind-$n" >/dev/null 2>&1 || true
  done
  kubectl config delete-context k3d-devops >/dev/null 2>&1 || true
  kubectl config delete-cluster k3d-devops >/dev/null 2>&1 || true
fi

echo "[CLEAN] Removing generated data..."
rm -rf "$ROOT_DIR/data" || true
mkdir -p "$ROOT_DIR/data"

echo "[CLEAN] Disconnecting Portainer from K3D networks..."
for net in $(docker network ls --format '{{.Name}}' | grep '^k3d-'); do
  docker network disconnect "$net" portainer-ce 2>/dev/null || true
done

echo "[CLEAN] Removing infrastructure network..."
remove_network() {
  local net="$1"
  # disconnect any attached containers first (avoid Resource is still in use)
  if docker network inspect "$net" >/dev/null 2>&1; then
    for c in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null); do
      [ -n "$c" ] && docker network disconnect -f "$net" "$c" >/dev/null 2>&1 || true
    done
    docker network rm "$net" >/dev/null 2>&1 || true
  fi
}

# try remove both infrastructure and shared k3d network
remove_network infrastructure
remove_network k3d-shared

echo "[CLEAN] Done."
