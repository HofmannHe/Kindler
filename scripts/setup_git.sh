#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"
: "${HAPROXY_HOST:=192.168.51.30}"

GITEA_URL="http://git.devops.${BASE_DOMAIN}"
GITEA_USER="gitea"
GITEA_PASSWORD="gitea123456"
GITEA_EMAIL="gitea@${BASE_DOMAIN}"

log() { echo "[setup_git] $*"; }

# 等待 Gitea 就绪
wait_gitea() {
  log "等待 Gitea 服务就绪..."
  local max_attempts=60
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if curl -sf "$GITEA_URL/api/v1/version" >/dev/null 2>&1; then
      log "✓ Gitea 服务已就绪"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  log "❌ Gitea 服务启动超时"
  return 1
}

# 检查并创建管理员用户
setup_admin() {
  log "配置 Gitea 管理员用户..."

  # 检查用户是否已存在
  if docker exec gitea gitea admin user list 2>/dev/null | grep -q "^ID.*Username"; then
    if docker exec gitea gitea admin user list 2>/dev/null | grep -q "$GITEA_USER"; then
      log "✓ 管理员用户已存在: $GITEA_USER"
      return 0
    fi
  fi

  # 创建管理员用户
  docker exec gitea gitea admin user create \
    --username "$GITEA_USER" \
    --password "$GITEA_PASSWORD" \
    --email "$GITEA_EMAIL" \
    --admin \
    --must-change-password=false 2>/dev/null || {
      log "⚠️  管理员用户可能已存在或创建失败，继续..."
    }

  log "✓ 管理员用户配置完成"
}

# 获取或创建 API Token
get_or_create_token() {
  log "获取 API Token..."

  # 尝试使用现有 token（如果已保存）
  local token_file="$ROOT_DIR/.gitea_token"
  if [ -f "$token_file" ]; then
    local token=$(cat "$token_file")
    # 验证 token 是否有效
    if curl -sf -H "Authorization: token $token" "$GITEA_URL/api/v1/user" >/dev/null 2>&1; then
      log "✓ 使用已存在的 API Token"
      echo "$token"
      return 0
    fi
  fi

  # 创建新 token
  local token=$(docker exec gitea gitea admin user generate-access-token \
    --username "$GITEA_USER" \
    --token-name "argocd-$(date +%s)" \
    --scopes "read:repository,write:repository" 2>/dev/null | grep -oP '(?<=token: ).*' || true)

  if [ -z "$token" ]; then
    log "❌ 创建 Token 失败"
    return 1
  fi

  echo "$token" > "$token_file"
  chmod 600 "$token_file"
  log "✓ API Token 已创建并保存"
  echo "$token"
}

# 创建仓库
create_repo() {
  local repo_name="$1"
  local token="$2"

  log "创建仓库: $repo_name"

  # 检查仓库是否存在
  if curl -sf -H "Authorization: token $token" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$repo_name" >/dev/null 2>&1; then
    log "✓ 仓库已存在: $repo_name"
    return 0
  fi

  # 创建仓库
  curl -sf -X POST \
    -H "Authorization: token $token" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$repo_name\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" \
    "$GITEA_URL/api/v1/user/repos" >/dev/null

  if [ $? -eq 0 ]; then
    log "✓ 仓库创建成功: $repo_name"
  else
    log "❌ 仓库创建失败: $repo_name"
    return 1
  fi
}

# 初始化 whoami 仓库的分支结构
init_whoami_repo() {
  local token="$1"
  local repo_name="whoami"
  local tmp_dir=$(mktemp -d)

  log "初始化 whoami 仓库分支..."

  cd "$tmp_dir"

  # 克隆仓库
  git clone "http://${GITEA_USER}:${token}@git.devops.${BASE_DOMAIN}/${GITEA_USER}/${repo_name}.git" >/dev/null 2>&1 || {
    log "❌ 克隆仓库失败"
    rm -rf "$tmp_dir"
    return 1
  }

  cd "$repo_name"
  git config user.name "Gitea Admin"
  git config user.email "$GITEA_EMAIL"

  # 创建 Helm Chart 结构
  mkdir -p deploy/templates

  # Chart.yaml
  cat > deploy/Chart.yaml <<'EOF'
apiVersion: v2
name: whoami
description: A simple whoami application for testing
type: application
version: 0.1.0
appVersion: "1.0"
EOF

  # values.yaml (默认值)
  cat > deploy/values.yaml <<EOF
image:
  repository: traefik/whoami
  tag: latest
  pullPolicy: IfNotPresent

replicaCount: 1

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  className: traefik
  host: whoami.dev.${BASE_DOMAIN}
  path: /
  pathType: Prefix
EOF

  # Deployment
  cat > deploy/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
    spec:
      containers:
      - name: whoami
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: 80
EOF

  # Service
  cat > deploy/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}
spec:
  type: {{ .Values.service.type }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: 80
  selector:
    app: {{ .Chart.Name }}
EOF

  # Ingress
  cat > deploy/templates/ingress.yaml <<'EOF'
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Chart.Name }}
  annotations:
    kubernetes.io/ingress.class: {{ .Values.ingress.className }}
spec:
  rules:
  - host: {{ .Values.ingress.host }}
    http:
      paths:
      - path: {{ .Values.ingress.path }}
        pathType: {{ .Values.ingress.pathType }}
        backend:
          service:
            name: {{ .Chart.Name }}
            port:
              number: {{ .Values.service.port }}
{{- end }}
EOF

  # README
  cat > README.md <<EOF
# Whoami Application

Simple test application for GitOps workflow demonstration.

## Branches

- \`develop\` → dev environment
- \`release\` → uat environment
- \`master\` → prod environment

## Deployment

Managed by ArgoCD ApplicationSet.
EOF

  git add .
  git commit -m "feat: 初始化 whoami Helm Chart" >/dev/null
  git push origin main >/dev/null

  # 创建 develop 分支
  git checkout -b develop >/dev/null 2>&1
  sed -i "s|host: whoami.dev.|host: whoami.dev.|" deploy/values.yaml
  git add deploy/values.yaml
  git commit -m "feat: develop 分支配置" >/dev/null || true
  git push -u origin develop >/dev/null 2>&1

  # 创建 release 分支
  git checkout -b release >/dev/null 2>&1
  sed -i "s|host: whoami.dev.|host: whoami.uat.|" deploy/values.yaml
  git add deploy/values.yaml
  git commit -m "feat: release 分支配置" >/dev/null || true
  git push -u origin release >/dev/null 2>&1

  # 创建 master 分支
  git checkout main >/dev/null 2>&1
  git checkout -b master >/dev/null 2>&1
  sed -i "s|host: whoami.dev.|host: whoami.prod.|" deploy/values.yaml
  git add deploy/values.yaml
  git commit -m "feat: master 分支配置" >/dev/null || true
  git push -u origin master >/dev/null 2>&1

  cd "$ROOT_DIR"
  rm -rf "$tmp_dir"

  log "✓ whoami 仓库分支初始化完成"
}

main() {
  wait_gitea || exit 1
  setup_admin

  local token
  token=$(get_or_create_token) || exit 1

  create_repo "whoami" "$token"
  init_whoami_repo "$token"

  log "✅ Gitea 设置完成"
  log "访问地址: $GITEA_URL"
  log "用户名: $GITEA_USER"
  log "密码: $GITEA_PASSWORD"
  log "Token: $token"
}

main "$@"
