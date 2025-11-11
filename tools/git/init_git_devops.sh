#!/usr/bin/env bash
# 初始化外部 Git 仓库的 devops 分支
# 包含 PostgreSQL 和其他 PaaS 服务的 manifests

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# 加载配置
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
fi

if [ -f "$ROOT_DIR/config/secrets.env" ]; then
  source "$ROOT_DIR/config/secrets.env"
fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-kindler123}"
GIT_REPO_URL="${GIT_REPO_URL:-http://git.devops.192.168.51.30.sslip.io/fc005/devops.git}"

echo "=========================================="
echo "  初始化外部 Git 仓库 devops 分支"
echo "=========================================="
echo ""
echo "Git 仓库: $GIT_REPO_URL"
echo ""

# 检查 Git 服务连通性
echo "[STEP 0/5] 检查 Git 服务连通性..."
if ! timeout 5 git ls-remote "$GIT_REPO_URL" &>/dev/null; then
  echo "⚠️  Git 服务不可用，跳过 devops 分支初始化"
  echo "    这不影响核心功能，GitOps 功能将在 Git 服务可用后自动启用"
  echo ""
  exit 0
fi
echo "✓ Git 服务可访问"
echo ""

# 临时工作目录
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

echo "[STEP 1/5] Clone Git 仓库..."
cd "$TMPDIR"
git clone "$GIT_REPO_URL" devops-repo 2>&1 | tail -3

cd devops-repo

# 配置 Git 用户（如果未配置）
git config user.name "${GIT_USERNAME:-kindler}" 2>/dev/null || true
git config user.email "${GIT_EMAIL:-kindler@kindler.local}" 2>/dev/null || true

echo ""
echo "[STEP 2/5] 创建或切换到 devops 分支..."
if git ls-remote --heads origin devops | grep -q devops; then
  echo "  devops 分支已存在，切换到该分支"
  git checkout devops
else
  echo "  devops 分支不存在，创建新分支"
  git checkout -b devops
fi

echo ""
echo "[STEP 3/5] 创建 PostgreSQL manifests..."
mkdir -p postgresql

# StatefulSet
cat > postgresql/statefulset.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: paas
  labels:
    app: postgresql
spec:
  ports:
  - port: 5432
    name: postgres
  clusterIP: None
  selector:
    app: postgresql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: paas
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
      - name: postgresql
        image: postgres:16-alpine
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgresql-secret
              key: username
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-secret
              key: password
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: postgresql-secret
              key: database
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/postgresql/data
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U kindler
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U kindler
          initialDelaySeconds: 5
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: postgresql-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: local-path
      resources:
        requests:
          storage: 2Gi
EOF

# Namespace
cat > postgresql/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: paas
  labels:
    name: paas
EOF

# README
cat > postgresql/README.md <<'EOF'
# PostgreSQL for Kindler

This directory contains PostgreSQL manifests for the Kindler platform.

## Components

- `namespace.yaml`: paas namespace
- `statefulset.yaml`: PostgreSQL StatefulSet and Service

## Deployment

Deployed via ArgoCD from the `devops` branch.

**Note**: The Secret `postgresql-secret` is created by the bootstrap script, not stored in Git.

## Connection

- Host: `postgresql.paas.svc.cluster.local`
- Port: `5432`
- User: `kindler`
- Database: `kindler`
EOF

echo ""
echo "[STEP 4/5] 提交 manifests..."
git add postgresql/
git commit -m "feat: add PostgreSQL manifests for devops cluster" || {
  echo "  (没有变更或已提交)"
}

echo ""
echo "[STEP 5/5] 推送到远程仓库..."
git push origin devops 2>&1 | tail -3

echo ""
echo "=========================================="
echo "✅ devops 分支初始化完成！"
echo "=========================================="
echo ""
echo "分支信息："
echo "  仓库: $GIT_REPO_URL"
echo "  分支: devops"
echo "  目录: postgresql/"
echo ""
echo "验证："
echo "  git ls-remote $GIT_REPO_URL | grep devops"
echo ""

