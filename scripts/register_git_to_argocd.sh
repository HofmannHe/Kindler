#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"

GITEA_URL="http://git.devops.${BASE_DOMAIN}"
GITEA_USER="gitea"
CLUSTER_NAME="${1:-devops}"

log() { echo "[register_git_to_argocd] $*"; }

# 读取 Gitea token
get_token() {
  local token_file="$ROOT_DIR/.gitea_token"
  if [ ! -f "$token_file" ]; then
    log "❌ Token 文件不存在: $token_file"
    log "请先运行 setup_git.sh"
    return 1
  fi
  cat "$token_file"
}

# 注册仓库到 ArgoCD
register_repo() {
  local token="$1"
  local repo_url="${GITEA_URL}/${GITEA_USER}/whoami.git"

  log "注册 Gitea 仓库到 ArgoCD..."

  # 检查仓库是否已注册
  if kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository 2>/dev/null | grep -q "gitea-whoami"; then
    log "✓ 仓库已注册"
    return 0
  fi

  # 创建 repository secret
  kubectl create secret generic gitea-whoami -n argocd \
    --from-literal=type=git \
    --from-literal=url="$repo_url" \
    --from-literal=username="$GITEA_USER" \
    --from-literal=password="$token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl label secret gitea-whoami -n argocd \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

  log "✓ 仓库已注册: $repo_url"
}

# 部署 ApplicationSet
deploy_applicationset() {
  log "部署 whoami ApplicationSet..."

  kubectl apply -f "$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml" >/dev/null

  log "✓ ApplicationSet 已部署"
}

main() {
  # 切换到 devops 集群上下文
  kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || {
    log "❌ 无法切换到集群 ${CLUSTER_NAME}"
    log "请确保 devops 集群已创建"
    return 1
  }

  local token
  token=$(get_token) || exit 1

  register_repo "$token"
  deploy_applicationset

  log "✅ Gitea 仓库已注册到 ArgoCD"
}

main "$@"
