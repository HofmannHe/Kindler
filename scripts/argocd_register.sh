#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

register_cluster_to_argocd() {
  local cluster_name="$1"
  local provider="${2:-k3d}"

  # 使用 kubectl 方式注册（不依赖 argocd CLI）
  "$ROOT_DIR"/scripts/argocd_register_kubectl.sh register "$cluster_name" "$provider"
}

unregister_cluster_from_argocd() {
  local cluster_name="$1"
  local provider="${2:-k3d}"

  # 使用 kubectl 方式注销（不依赖 argocd CLI）
  "$ROOT_DIR"/scripts/argocd_register_kubectl.sh unregister "$cluster_name" "$provider"
}

# Main logic
action="${1:-register}"
cluster_name="${2:-}"
provider="${3:-k3d}"

if [[ -z "$cluster_name" ]]; then
  echo "Usage: $0 <register|unregister> <cluster_name> [provider]"
  echo "Example: $0 register dev-k3d k3d"
  echo "Example: $0 unregister dev-k3d"
  exit 1
fi

case "$action" in
  register)
    register_cluster_to_argocd "$cluster_name" "$provider"
    ;;
  unregister)
    unregister_cluster_from_argocd "$cluster_name"
    ;;
  *)
    echo "[ERROR] Unknown action: $action"
    echo "Usage: $0 <register|unregister> <cluster_name> [provider]"
    exit 1
    ;;
esac
