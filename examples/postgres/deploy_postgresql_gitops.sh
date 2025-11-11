#!/usr/bin/env bash
# 通过 ArgoCD 部署 PostgreSQL（GitOps 方式）

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo "  通过 ArgoCD 部署 PostgreSQL (GitOps)"
echo "=========================================="
echo ""

# 加载配置
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
fi

if [ -f "$ROOT_DIR/config/secrets.env" ]; then
  source "$ROOT_DIR/config/secrets.env"
fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-kindler123}"
GIT_REPO_URL="${GIT_REPO_URL:-http://git.devops.192.168.51.30.sslip.io/fc005/devops.git}"

echo "[STEP 0/4] 预拉取 PostgreSQL 镜像"
# 加载镜像预拉取函数
source "$ROOT_DIR/scripts/lib/lib.sh"
if prefetch_image "postgres:16-alpine"; then
  echo "  [+] postgres:16-alpine"
  k3d image import "postgres:16-alpine" -c devops >/dev/null 2>&1 || echo "  [WARN] 导入失败，将在集群中直接拉取"
else
  echo "  [WARN] 预拉取失败: postgres:16-alpine"
fi
echo ""

echo "[STEP 1/4] 创建 namespace: paas"
kubectl --context k3d-devops create namespace paas --dry-run=client -o yaml | \
  kubectl --context k3d-devops apply -f -

echo ""
echo "[STEP 2/4] 创建 Secret: postgresql-secret"
kubectl --context k3d-devops create secret generic postgresql-secret \
  --namespace=paas \
  --from-literal=username=kindler \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --from-literal=database=kindler \
  --dry-run=client -o yaml | kubectl --context k3d-devops apply -f -

echo ""
echo "[STEP 3/4] 创建 ArgoCD Application for PostgreSQL"
cat <<EOF | kubectl --context k3d-devops apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgresql
  namespace: argocd
  labels:
    app: postgresql
    managed-by: argocd
spec:
  project: default
  source:
    repoURL: $GIT_REPO_URL
    targetRevision: devops
    path: postgresql
  destination:
    server: https://kubernetes.default.svc
    namespace: paas
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
  ignoreDifferences:
  - group: ""
    kind: Secret
    name: postgresql-secret
    jsonPointers:
    - /data
EOF

echo ""
echo "[STEP 4/4] 等待 ArgoCD 同步 PostgreSQL..."
echo "  (ArgoCD 将从 Git 仓库 $GIT_REPO_URL 的 devops 分支部署)"

# 等待 Application 就绪
for i in {1..30}; do
  sync_status=$(kubectl --context k3d-devops get application postgresql -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  health_status=$(kubectl --context k3d-devops get application postgresql -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  
  echo "  [$i/30] Sync: $sync_status, Health: $health_status"
  
  if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
    echo ""
    echo "✓ PostgreSQL Application 同步成功！"
    break
  fi
  
  if [ $i -eq 30 ]; then
    echo ""
    echo "[WARN] ArgoCD 同步超时，请手动检查："
    echo "  kubectl --context k3d-devops get application postgresql -n argocd"
    echo "  kubectl --context k3d-devops get pods -n paas"
    break
  fi
  
  sleep 2
done

echo ""
echo "[验证] 等待 PostgreSQL Pod 就绪（最多 60 秒）..."
kubectl --context k3d-devops wait --for=condition=ready pod \
  -l app=postgresql -n paas --timeout=60s 2>/dev/null || {
    echo "[WARN] PostgreSQL Pod 尚未就绪，请稍后检查"
    kubectl --context k3d-devops get pods -n paas
  }

echo ""
echo "[测试] 测试 PostgreSQL 连接"
kubectl --context k3d-devops exec -i postgresql-0 -n paas -- \
  psql -U kindler -d kindler -c 'SELECT version();' 2>/dev/null | head -3 || {
    echo "[WARN] PostgreSQL 连接测试失败，可能还在启动中"
  }

echo ""
echo "=========================================="
echo "✅ PostgreSQL GitOps 部署完成！"
echo "=========================================="
echo ""
echo "ArgoCD Application 信息："
echo "  Name:      postgresql"
echo "  Namespace: argocd"
echo "  Git Repo:  $GIT_REPO_URL"
echo "  Git Path:  postgresql"
echo "  Git Branch: devops"
echo ""
echo "PostgreSQL 服务信息："
echo "  Pod:       postgresql-0"
echo "  Namespace: paas"
echo "  用户:      kindler"
echo "  数据库:    kindler"
echo ""
echo "查看 ArgoCD Application 状态："
echo "  kubectl --context k3d-devops get application postgresql -n argocd"
echo ""
echo "查看 PostgreSQL 日志："
echo "  kubectl --context k3d-devops logs -f postgresql-0 -n paas"
echo ""
