#!/usr/bin/env bash
# 为单个集群创建 Git 分支（含 whoami manifests）
# 幂等操作：分支已存在则更新，不存在则创建

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GITOPS_LOCK_FILE="${GITOPS_LOCK_FILE:-/tmp/kindler_gitops.lock}"

# 加载配置
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
fi

GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_USERNAME="${GIT_USERNAME:-codex}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

usage() {
  echo "Usage: $0 <cluster-name>" >&2
  echo "Example: $0 dev" >&2
  exit 1
}

if [ $# -ne 1 ]; then
  usage
fi

CLUSTER_NAME="$1"

if [ -z "$GIT_REPO_URL" ]; then
  echo "[ERROR] GIT_REPO_URL not set in config/git.env" >&2
  exit 1
fi

echo "=========================================="
echo "  创建 Git 分支: $CLUSTER_NAME"
echo "=========================================="
echo ""

# 提取环境名（去掉 -k3d/-kind 后缀）
env_name="${CLUSTER_NAME%-k3d}"
env_name="${env_name%-kind}"

# 临时工作目录
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

cd "$TMPDIR"

# Clone 仓库
echo "[1/5] Cloning repository..."
if [ -n "$GIT_PASSWORD" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
  git clone "$GIT_REPO_URL_AUTH" repo 2>&1 | grep -v "password" || true
else
  git clone "$GIT_REPO_URL" repo
fi

cd repo

if [ -n "$GIT_PASSWORD" ]; then
  PUSH_REMOTE="$GIT_REPO_URL_AUTH"
else
  PUSH_REMOTE="origin"
fi

# 检查分支是否存在
echo "[2/5] Checking if branch exists..."
if git ls-remote --heads origin "$CLUSTER_NAME" | grep -q "$CLUSTER_NAME"; then
  echo "  Branch '$CLUSTER_NAME' exists, checking out..."
  git checkout "$CLUSTER_NAME" 2>/dev/null || git checkout -b "$CLUSTER_NAME" "origin/$CLUSTER_NAME"
else
  echo "  Creating new branch: $CLUSTER_NAME"
  git checkout -b "$CLUSTER_NAME"
fi

# 创建 deploy/ 目录
mkdir -p deploy/templates

# 创建 Helm Chart.yaml
echo "[3/5] Creating Helm Chart structure..."
cat > deploy/Chart.yaml <<EOF
apiVersion: v2
name: whoami
description: Simple whoami application
type: application
version: 0.1.0
EOF

# 创建 values.yaml（使用显式变量替换确保正确）
# 确定 ingress class：k3d 使用 traefik，kind 使用 nginx
if echo "$CLUSTER_NAME" | grep -q "k3d"; then
  ingress_class="traefik"
else
  ingress_class="nginx"
fi

cat > deploy/values.yaml <<VALUESEOF
# whoami Helm Chart values for $CLUSTER_NAME (env: $env_name)
replicaCount: 1

image:
  repository: traefik/whoami
  tag: v1.10.2
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  className: $ingress_class
  host: whoami.$env_name.192.168.51.30.sslip.io
  path: /
  pathType: Prefix

resources:
  limits:
    cpu: 100m
    memory: 64Mi
  requests:
    cpu: 50m
    memory: 32Mi
VALUESEOF

# 创建 templates/deployment.yaml
cat > deploy/templates/deployment.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: whoami
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: whoami
  labels:
    app: whoami
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
      - name: whoami
        image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: 80
          name: http
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        livenessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: whoami
  labels:
    app: whoami
spec:
  type: {{ .Values.service.type }}
  selector:
    app: whoami
  ports:
  - port: {{ .Values.service.port }}
    targetPort: http
    protocol: TCP
    name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
  namespace: whoami
  labels:
    app: whoami
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
  - host: {{ .Values.ingress.host }}
    http:
      paths:
      - path: {{ .Values.ingress.path }}
        pathType: {{ .Values.ingress.pathType }}
        backend:
          service:
            name: whoami
            port:
              number: {{ .Values.service.port }}
EOF

# 创建 README.md
cat > deploy/README.md <<EOF
# whoami Application - $CLUSTER_NAME

This directory contains Kubernetes manifests for the whoami demo application.

## Deployment
- **Cluster**: $CLUSTER_NAME
- **Namespace**: whoami
- **Ingress**: http://whoami.${env_name}.192.168.51.30.sslip.io

## Files
- \`Chart.yaml\`: Helm Chart metadata
- \`values.yaml\`: Configuration values
- \`templates/deployment.yaml\`: Kubernetes Deployment, Service, and Ingress

## Managed by ArgoCD
This application is automatically deployed and synchronized by ArgoCD ApplicationSet.
EOF

# Commit
echo "[4/5] Committing changes..."
git add deploy/
if git diff --cached --quiet; then
  echo "  No changes to commit (manifests already up to date)"
else
  git commit -m "feat: add/update whoami manifests for $CLUSTER_NAME cluster"
  echo "  ✓ Changes committed"
fi

# Push
echo "[5/5] Pushing branch $CLUSTER_NAME..."
# Serialize pushes across processes to avoid intermittent remote update races
if command -v flock >/dev/null 2>&1; then
  exec 209>"$GITOPS_LOCK_FILE"
  flock -x 209
fi

push_with_retry() {
  local tries=0 max=5 delay=2 rc=0
  while [ $tries -lt $max ]; do
    tries=$((tries + 1))
    if [ -n "$GIT_PASSWORD" ] && [ "$PUSH_REMOTE" = "$GIT_REPO_URL_AUTH" ]; then
      git push "$PUSH_REMOTE" "$CLUSTER_NAME" 2>&1 | grep -v "password" || true
      rc=${PIPESTATUS[0]}
    else
      git push "$PUSH_REMOTE" "$CLUSTER_NAME" || true
      rc=$?
    fi
    if [ $rc -eq 0 ]; then
      echo "  ✓ push succeeded (attempt $tries)"
      return 0
    fi
    echo "  ⚠ push failed (attempt $tries/$max, rc=$rc); fetching and retrying..." >&2
    git fetch --prune origin >/dev/null 2>&1 || true
    git rebase "origin/$CLUSTER_NAME" >/dev/null 2>&1 || true
    sleep $((delay * tries))
  done
  echo "  ✗ push failed after ${max} attempts" >&2
  return $rc
}

if ! push_with_retry; then
  exit 1
fi

if command -v flock >/dev/null 2>&1; then
  flock -u 209 2>/dev/null || true
  exec 209>&- 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "✅ Git 分支 $CLUSTER_NAME 已创建/更新！"
echo "=========================================="
echo ""
echo "验证："
echo "  git ls-remote $GIT_REPO_URL | grep $CLUSTER_NAME"
