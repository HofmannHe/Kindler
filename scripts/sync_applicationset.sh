#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Generate ArgoCD ApplicationSet definitions from SQLite and optionally lock during updates.
# Usage: scripts/sync_applicationset.sh
# Category: gitops
# Status: stable
# See also: scripts/reconcile.sh, tools/git/sync_git_from_db.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"

CONFIG_FILE="$ROOT_DIR/config/git.env"
LOCK_FILE="${APPSET_SYNC_LOCK:-/tmp/applicationset_sync.lock}"

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

APPSET_FILE="$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml"

log() { echo "[sync_applicationset] $*"; }

# 分支名 = 环境名（严格一一对应）
get_branch_for_env() { echo "$1"; }

# 从数据库读取集群列表并生成 ApplicationSet
generate_applicationset() {
  # acquire process-level lock to avoid concurrent file writes/applies
  if command -v flock > /dev/null 2>&1; then
    exec 203> "$LOCK_FILE"
    flock -x 203
  fi
  log "从数据库读取集群列表并生成 ApplicationSet..."

  # 检查数据库可用性
  if ! db_is_available > /dev/null 2>&1; then
    log "⚠️  数据库不可用，ApplicationSet 不会更新"
    log "  ArgoCD 将继续使用现有的 ApplicationSet 配置"
    return 0
  fi

  local elements=""
  local first=1
  local cluster_count=0

  # 从数据库读取所有集群（排除 devops），但只包含实际存在的集群
  while IFS='|' read -r name provider _; do
    # 跳过 devops 环境（不部署 whoami）
    [[ "$name" == "devops" ]] && continue

    # 验证集群是否实际存在（检查 kubectl context）
    local ctx=""
    if [ "$provider" = "k3d" ]; then
      ctx="k3d-${name}"
    else
      ctx="kind-${name}"
    fi

    # 验证集群是否存在且可访问
    if ! kubectl --context "$ctx" get nodes > /dev/null 2>&1; then
      log "  ⚠ 跳过不存在的集群: $name (context: $ctx)"
      continue
    fi

    # 分支名 = 集群名（一对一映射）
    local branch="$name"
    local host_env="$name"
    local ingress_class="traefik"

    if [ $first -eq 1 ]; then
      first=0
    else
      elements="${elements}
"
    fi

    elements="${elements}      - env: ${name}
        hostEnv: ${host_env}
        branch: ${branch}
        clusterName: ${name}
        ingressClass: ${ingress_class}"

    cluster_count=$((cluster_count + 1))
    log "  ✓ 添加集群: $name ($provider, context: $ctx)"
  done < <(sqlite_query "SELECT name, provider, node_port FROM clusters WHERE name != 'devops' ORDER BY name;" 2> /dev/null || echo "")

  if [ $cluster_count -eq 0 ]; then
    log "⚠️  数据库中没有业务集群记录"
    log "  创建集群后会自动更新 ApplicationSet"
    return 0
  fi

  log "  发现 $cluster_count 个业务集群"

  # 生成 ApplicationSet YAML（使用 List Generator + 数据库数据源）
  cat > "$APPSET_FILE" << EOF
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
      # 自动从数据库读取（通过 scripts/sync_applicationset.sh）
      # 数据流：Database (clusters表) → Git Branch → ArgoCD Application
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
        repoURL: '${GIT_REPO_URL}'
        path: deploy
        # 每个集群对应一个同名的 Git 分支
        targetRevision: '{{.branch}}'
        helm:
          releaseName: whoami
          parameters:
          # 动态设置 Ingress host
          - name: ingress.host
            value: 'whoami.{{.hostEnv}}.${BASE_DOMAIN}'
          # 统一使用 traefik Ingress Controller
          - name: ingress.className
            value: '{{.ingressClass}}'
          # 使用固定 tag，避免 :latest 触发 Always 拉取
          - name: image.tag
            value: 'v1.10.2'
          - name: image.pullPolicy
            value: 'IfNotPresent'
      destination:
        # 部署到对应的集群
        name: '{{.clusterName}}'
        namespace: whoami
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
EOF

  log "✓ ApplicationSet 已生成: $APPSET_FILE"
  log "  数据源：Database (clusters表，排除 devops)"
  log "  集群数量：$cluster_count"
  log "  数据流：Database → Git Branch → ArgoCD Application"
  # release lock after file generation; apply step below is quick, but we keep the lock
}

# 应用 ApplicationSet 到 ArgoCD
apply_applicationset() {
  log "应用 ApplicationSet 到 ArgoCD..."

  if ! kubectl --context k3d-devops get ns argocd > /dev/null 2>&1; then
    log "⚠️  devops 集群未就绪，跳过应用"
    return 0
  fi

  kubectl --context k3d-devops apply -f "$APPSET_FILE" > /dev/null 2>&1 || {
    log "⚠️  应用 ApplicationSet 失败（devops 集群可能未就绪）"
    # ensure we release lock even on failure
    if command -v flock > /dev/null 2>&1; then
      flock -u 203 2> /dev/null || true
      exec 203>&- 2> /dev/null || true
    fi
    return 0
  }

  log "✓ ApplicationSet 已应用到 ArgoCD"
  if command -v flock > /dev/null 2>&1; then
    flock -u 203 2> /dev/null || true
    exec 203>&- 2> /dev/null || true
  fi
}

main() {
  generate_applicationset
  apply_applicationset
  log "✅ ApplicationSet 同步完成"
}

main "$@"
