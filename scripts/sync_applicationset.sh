#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"

APPSET_FILE="$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml"
CSV_FILE="$ROOT_DIR/config/environments.csv"

log() { echo "[sync_applicationset] $*"; }

# 环境名到分支的映射
get_branch_for_env() {
  local env="$1"
  case "$env" in
    dev*) echo "develop" ;;
    uat*) echo "release" ;;
    prod*) echo "master" ;;
    *) echo "main" ;;
  esac
}

# 读取 environments.csv 生成 ApplicationSet
generate_applicationset() {
  log "读取 environments.csv 生成 ApplicationSet..."

  if [ ! -f "$CSV_FILE" ]; then
    log "❌ 找不到 $CSV_FILE"
    return 1
  fi

  local elements=""
  local first=1

  # 读取 CSV（跳过注释和空行）
  while IFS=, read -r env provider node_port pf_port reg_portainer haproxy_route http_port https_port; do
    # 跳过注释和空行
    [[ "$env" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$env" ]] && continue

    # 跳过 devops 环境（不部署 whoami）
    [[ "$env" == "devops" ]] && continue

    local branch=$(get_branch_for_env "$env")

    if [ $first -eq 1 ]; then
      first=0
    else
      elements="${elements}
"
    fi

    elements="${elements}      - env: ${env}
        branch: ${branch}
        clusterName: ${env}"

  done < <(grep -v '^[[:space:]]*$' "$CSV_FILE")

  # 生成 ApplicationSet YAML
  cat > "$APPSET_FILE" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: whoami
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
  - list:
      elements:
      # 自动从 environments.csv 生成（通过 scripts/sync_applicationset.sh）
${elements}
  template:
    metadata:
      name: 'whoami-{{.env}}'
      labels:
        app: whoami
        env: '{{.env}}'
    spec:
      project: default
      source:
        repoURL: http://git.devops.${BASE_DOMAIN}/gitea/whoami.git
        path: deploy
        targetRevision: '{{.branch}}'
        helm:
          releaseName: whoami
          parameters:
          # 动态设置 Ingress host
          - name: ingress.host
            value: 'whoami.{{.env}}.${BASE_DOMAIN}'
      destination:
        # 部署到对应的集群
        name: '{{.clusterName}}'
        namespace: default
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
EOF

  log "✓ ApplicationSet 已生成: $APPSET_FILE"
}

# 应用 ApplicationSet 到 ArgoCD
apply_applicationset() {
  log "应用 ApplicationSet 到 ArgoCD..."

  if ! kubectl config use-context k3d-devops >/dev/null 2>&1; then
    log "⚠️  无法切换到 k3d-devops 上下文，跳过应用"
    return 0
  fi

  kubectl apply -f "$APPSET_FILE" >/dev/null 2>&1 || {
    log "⚠️  应用 ApplicationSet 失败（devops 集群可能未就绪）"
    return 0
  }

  log "✓ ApplicationSet 已应用到 ArgoCD"
}

main() {
  generate_applicationset
  apply_applicationset
  log "✅ ApplicationSet 同步完成"
}

main "$@"
