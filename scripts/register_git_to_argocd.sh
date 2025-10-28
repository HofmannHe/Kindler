#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

CONFIG_FILE="$ROOT_DIR/config/git.env"

log() { echo "[register_git_to_argocd] $*"; }

if [ ! -f "$CONFIG_FILE" ]; then
  log "❌ 未找到配置文件 $CONFIG_FILE (请复制 config/git.env.example 并填写)"
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

if [ -f "$ROOT_DIR/config/secrets.env" ]; then
  # shellcheck disable=SC1090
  . "$ROOT_DIR/config/secrets.env"
fi

: "${GIT_REPO_URL:?请在 config/git.env 中设置 GIT_REPO_URL}"
GIT_USERNAME="${GIT_USERNAME:-}"
GIT_PASSWORD="${GIT_PASSWORD:-}"
SECRET_NAME="${ARGOCD_REPO_SECRET_NAME:-external-git-whoami}"
CLUSTER_NAME="${1:-devops}"

register_repo() {
  local repo_url="$1"

  log "注册外部 Git 仓库到 ArgoCD..."

  local args=("--from-literal=type=git" "--from-literal=url=${repo_url}")
  if [ -n "$GIT_USERNAME" ]; then
    args+=("--from-literal=username=${GIT_USERNAME}")
  fi
  if [ -n "$GIT_PASSWORD" ]; then
    args+=("--from-literal=password=${GIT_PASSWORD}")
  fi

  kubectl create secret generic "$SECRET_NAME" -n argocd \
    "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl label secret "$SECRET_NAME" -n argocd \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

  log "✓ 仓库已注册: ${repo_url}"
}

deploy_applicationset() {
  log "部署 whoami ApplicationSet（动态生成）..."
  # 使用动态生成而非静态文件，确保与数据库一致
  if [ -f "$ROOT_DIR/scripts/sync_applicationset.sh" ]; then
    "$ROOT_DIR/scripts/sync_applicationset.sh" 2>&1 | sed 's/^/  /'
    log "✓ ApplicationSet 已部署（数据源：Database）"
  else
    log "⚠️  sync_applicationset.sh not found, using static file"
    kubectl apply -f "$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml" >/dev/null
    log "✓ ApplicationSet 已部署（数据源：Static file）"
  fi
}

main() {
  kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || {
    log "❌ 无法切换到集群 ${CLUSTER_NAME}"
    log "请确保 devops 集群已创建"
    return 1
  }

  if [ -z "$GIT_USERNAME" ] || [ -z "$GIT_PASSWORD" ]; then
    log "⚠️  未提供仓库凭证，将以匿名方式注册（仅适用于公开仓库）"
  else
    log "✓ 已加载仓库凭证 (${GIT_USERNAME})"
  fi

  register_repo "$GIT_REPO_URL"
  deploy_applicationset

  log "✅ 外部 Git 仓库已注册到 ArgoCD"
}

main "$@"
