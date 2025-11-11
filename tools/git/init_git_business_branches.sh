#!/usr/bin/env bash
# 初始化外部 Git 仓库的业务分支
# 为每个业务集群创建分支并添加 whoami 应用 manifests

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# 加载配置
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
fi

GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_USERNAME="${GIT_USERNAME:-codex}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

if [ -z "$GIT_REPO_URL" ]; then
  echo "[ERROR] GIT_REPO_URL is not set in config/git.env" >&2
  exit 1
fi

echo "=========================================="
echo "  初始化业务分支（whoami manifests）"
echo "=========================================="
echo ""

# 临时工作目录
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

cd "$TMPDIR"

# Clone 仓库
echo "[1/4] Cloning repository..."
if [ -n "$GIT_PASSWORD" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
  git clone "$GIT_REPO_URL_AUTH" repo
else
  git clone "$GIT_REPO_URL" repo
fi

cd repo

# 读取业务集群列表（排除 devops）
echo "[2/4] Reading business clusters from environments.csv..."
CLUSTERS=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv")

if [ -z "$CLUSTERS" ]; then
  echo "[ERROR] No business clusters found in environments.csv" >&2
  exit 1
fi

echo "Business clusters: $(echo $CLUSTERS | tr '\n' ' ')"
echo ""

# 为每个集群创建分支和 manifests
echo "[3/4] Creating branches and whoami manifests..."
for cluster in $CLUSTERS; do
  echo ""
  echo "Processing cluster: $cluster"
  
  # 提取环境名（去掉 -k3d/-kind 后缀）
  env_name="${cluster%-k3d}"
  env_name="${env_name%-kind}"
  
  # 检查分支是否存在
  if git ls-remote --heads origin "$cluster" | grep -q "$cluster"; then
    echo "  Branch '$cluster' already exists, checking out..."
    git checkout "$cluster" 2>/dev/null || git checkout -b "$cluster" "origin/$cluster"
  else
    echo "  Creating new branch: $cluster"
    git checkout -b "$cluster"
  fi
  
  # 创建 deploy/ 目录
  mkdir -p deploy
  
  # 创建 whoami Helm Chart values
  cat > deploy/values.yaml <<EOF
# whoami Helm Chart values for $cluster
# 使用内联 manifests，不依赖外部 Helm Chart

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
  className: nginx
  host: whoami.${env_name}.192.168.51.30.sslip.io
  path: /
  pathType: Prefix

resources:
  limits:
    cpu: 100m
    memory: 64Mi
  requests:
    cpu: 50m
    memory: 32Mi
EOF

  # 创建 Kubernetes manifests
  cat > deploy/deployment.yaml <<EOF
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
  replicas: 1
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
        image: traefik/whoami:v1.10.2
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
          name: http
        resources:
          limits:
            cpu: 100m
            memory: 64Mi
          requests:
            cpu: 50m
            memory: 32Mi
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
  type: ClusterIP
  selector:
    app: whoami
  ports:
  - port: 80
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
  ingressClassName: nginx
  rules:
  - host: whoami.${env_name}.192.168.51.30.sslip.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: whoami
            port:
              number: 80
EOF

  # 创建 README
  cat > deploy/README.md <<EOF
# whoami Application - $cluster

This directory contains Kubernetes manifests for the whoami demo application.

## Deployment
- **Cluster**: $cluster
- **Namespace**: whoami
- **Ingress**: http://whoami.${env_name}.192.168.51.30.sslip.io

## Files
- \`deployment.yaml\`: Kubernetes Deployment, Service, and Ingress
- \`values.yaml\`: Configuration values (for reference)

## Managed by ArgoCD
This application is automatically deployed and synchronized by ArgoCD ApplicationSet.
EOF

  # Commit
  git add deploy/
  if git diff --cached --quiet; then
    echo "  No changes to commit (manifests already exist)"
  else
    git commit -m "feat: add whoami manifests for $cluster cluster"
    echo "  ✓ Committed whoami manifests"
  fi
  
  # Push
  echo "  Pushing branch $cluster..."
  if [ -n "$GIT_PASSWORD" ]; then
    git push "$GIT_REPO_URL_AUTH" "$cluster" 2>&1 | grep -v "password" || true
  else
    git push origin "$cluster"
  fi
  
  echo "  ✓ Branch $cluster initialized"
done

echo ""
echo "[4/4] Verifying branches..."
git ls-remote --heads origin | grep -E "dev|uat|prod"

echo ""
echo "=========================================="
echo "✅ All business branches initialized!"
echo "=========================================="
echo ""
echo "Branches created:"
for cluster in $CLUSTERS; do
  echo "  - $cluster"
done
echo ""
echo "Next steps:"
echo "  1. ArgoCD will automatically sync applications"
echo "  2. Verify: kubectl --context k3d-devops get applications -n argocd"
echo "  3. Check: curl http://whoami.<env>.192.168.51.30.sslip.io"
echo ""

