#!/usr/bin/env bash
# 修复所有集群的 Ingress Controller 问题
# 不绕过 HAProxy，通过 HAProxy 访问服务

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo "  修复 Ingress Controllers"
echo "=========================================="
echo ""

## 第一部分：修复 k3d 集群的 Traefik
echo "[1/3] 修复 k3d 集群 Traefik 安装问题"
echo ""

for cluster in dev-k3d uat-k3d prod-k3d; do
  echo "-- Fixing $cluster --"
  ctx="k3d-$cluster"
  
  # 删除错误的 IngressClass（缺少 Helm 元数据）
  echo "  Deleting invalid IngressClass..."
  kubectl --context "$ctx" delete ingressclass traefik --ignore-not-found=true
  
  # 删除失败的 Helm Job
  echo "  Deleting failed Helm Job..."
  kubectl --context "$ctx" delete job -n kube-system helm-install-traefik --ignore-not-found=true
  
  # 重新创建 Job（从 k3d 自带的 HelmChart CRD）
  echo "  Recreating Helm install Job..."
  kubectl --context "$ctx" delete pod -n kube-system -l job-name=helm-install-traefik --grace-period=0 --force --ignore-not-found=true
  
  # 触发 HelmChart controller 重新创建 Job
  kubectl --context "$ctx" annotate helmchart -n kube-system traefik helm.cattle.io/force-update="$(date +%s)" --overwrite
  
  echo "  ✓ Triggered Traefik reinstall"
  echo ""
done

echo "等待 30 秒让 Traefik 重新安装..."
sleep 30

echo ""
echo "[2/3] 验证 k3d Traefik 状态"
for cluster in dev-k3d uat-k3d prod-k3d; do
  ctx="k3d-$cluster"
  echo "-- $cluster --"
  
  # 检查 Traefik pod
  traefik_running=$(kubectl --context "$ctx" get pods -n kube-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null || echo "")
  
  if [ -n "$traefik_running" ]; then
    echo "  ✓ Traefik pod running: $traefik_running"
  else
    echo "  ⚠ Traefik not running yet (may need more time)"
    # 检查 Job 状态
    job_status=$(kubectl --context "$ctx" get job -n kube-system helm-install-traefik -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    echo "    Helm Job status: succeeded=$job_status"
  fi
done

echo ""
echo "[3/3] 安装 ingress-nginx 到 kind 集群"
echo ""

# 下载 ingress-nginx manifest（在宿主机上，不经过 HAProxy）
MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml"
MANIFEST_FILE="/tmp/ingress-nginx-kind.yaml"

echo "Downloading ingress-nginx manifest..."
if command -v wget >/dev/null 2>&1; then
  wget -q -O "$MANIFEST_FILE" "$MANIFEST_URL"
else
  curl -sL -o "$MANIFEST_FILE" "$MANIFEST_URL"
fi

if [ ! -s "$MANIFEST_FILE" ]; then
  echo "[ERROR] Failed to download manifest" >&2
  exit 1
fi

echo "Downloaded $(wc -l < "$MANIFEST_FILE") lines"
echo ""

for cluster in dev uat prod; do
  echo "-- Installing to kind-$cluster --"
  ctx="kind-$cluster"
  
  # 应用 manifest
  kubectl --context "$ctx" apply -f "$MANIFEST_FILE" 2>&1 | grep -E "created|configured" | wc -l | xargs echo "  Resources created/configured:"
  
  echo "  ✓ Applied"
done

echo ""
echo "等待 ingress-nginx pods 就绪..."
sleep 15

for cluster in dev uat prod; do
  ctx="kind-$cluster"
  echo "-- $cluster --"
  
  # 等待 controller pod 就绪
  if kubectl --context "$ctx" wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s >/dev/null 2>&1; then
    echo "  ✓ Ingress controller ready"
  else
    echo "  ⚠ Controller not ready yet (may need more time)"
    kubectl --context "$ctx" get pods -n ingress-nginx 2>&1 | grep controller || true
  fi
done

echo ""
echo "=========================================="
echo "✅ Ingress Controllers 修复完成"
echo "=========================================="
echo ""
echo "后续步骤："
echo "1. 等待所有 pods 完全就绪（可能需要 1-2 分钟）"
echo "2. 测试 HTTP 访问："
echo "   curl -v http://whoami.dev.192.168.51.30.sslip.io"
echo "3. 执行完整回归测试：tests/run_tests.sh all"

