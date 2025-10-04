#!/bin/bash
# ArgoCD 完整部署脚本
# 用途: 在 k3d 集群中部署 ArgoCD 并通过 HAProxy 暴露

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CLUSTER_NAME="${1:-argocd-demo}"

echo "========================================"
echo "ArgoCD 部署脚本"
echo "========================================"
echo "集群名称: $CLUSTER_NAME"
echo ""

# 1. 检查集群是否存在
if ! k3d cluster list | grep -q "$CLUSTER_NAME"; then
    echo "❌ 集群 '$CLUSTER_NAME' 不存在"
    echo "请先创建集群: k3d cluster create $CLUSTER_NAME --api-port 6550 -p 8001:80@loadbalancer -p 7443:443@loadbalancer"
    exit 1
fi

echo "✓ 集群 '$CLUSTER_NAME' 已存在"
echo ""

# 2. 导入镜像
echo "步骤 1: 导入必需镜像..."
k3d image import nginx:alpine rancher/mirrored-pause:3.6 rancher/mirrored-coredns-coredns:1.12.0 -c "$CLUSTER_NAME" 2>/dev/null || true
echo "✓ 镜像导入完成"
echo ""

# 3. 等待 CoreDNS 就绪
echo "步骤 2: 等待 CoreDNS 就绪..."
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=60s
echo "✓ CoreDNS 就绪"
echo ""

# 4. 部署 ArgoCD
echo "步骤 3: 部署 ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT_DIR/manifests/argocd/argocd-standalone.yaml"
kubectl apply -f "$ROOT_DIR/manifests/argocd/argocd-ingress.yaml"

echo "等待 ArgoCD Pod 就绪..."
kubectl wait --for=condition=ready pod -l app=argocd-server -n argocd --timeout=60s
echo "✓ ArgoCD 部署完成"
echo ""

# 5. 获取节点 IP
echo "步骤 4: 配置 HAProxy..."
K3D_NODE_IP=$(docker inspect "k3d-${CLUSTER_NAME}-server-0" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "k3d 节点 IP: $K3D_NODE_IP"

# 6. 更新 HAProxy 配置
HAPROXY_CFG="$ROOT_DIR/compose/haproxy/haproxy.cfg"

# 检查是否已存在 argocd 配置
if grep -q "host_argocd" "$HAPROXY_CFG"; then
    # 更新现有配置
    sed -i "s|backend be_argocd.*|backend be_argocd\n  server s1 $K3D_NODE_IP:30800|" "$HAPROXY_CFG"
    echo "✓ HAProxy 配置已更新"
else
    echo "⚠️  HAProxy 配置中未找到 ArgoCD 路由，请手动添加"
fi

# 7. 重启 HAProxy
if docker ps --filter "name=haproxy-gw" --format "{{.Names}}" | grep -q haproxy-gw; then
    docker compose -f "$ROOT_DIR/compose/haproxy/docker-compose.yml" restart
    echo "✓ HAProxy 已重启"
else
    docker compose -f "$ROOT_DIR/compose/haproxy/docker-compose.yml" up -d
    echo "✓ HAProxy 已启动"
fi
echo ""

# 8. 验证部署
echo "步骤 5: 验证部署..."
sleep 5

echo ""
echo "kubectl 资源:"
kubectl get pods,svc,ingress -n argocd

echo ""
echo "访问测试:"
RESPONSE=$(curl -s -H "Host: argocd.local" http://localhost:23080 | grep -o "<title>.*</title>" | sed 's/<[^>]*>//g' || echo "访问失败")
echo "  响应: $RESPONSE"

echo ""
echo "========================================"
echo "✅ ArgoCD 部署完成！"
echo "========================================"
echo ""
echo "访问方式:"
echo "  1. 命令行测试:"
echo "     curl -H 'Host: argocd.local' http://localhost:23080"
echo ""
echo "  2. 浏览器访问:"
echo "     a. 编辑 /etc/hosts 添加: 127.0.0.1  argocd.local"
echo "     b. 访问: http://argocd.local:23080"
echo ""
echo "配置信息:"
echo "  - 集群: $CLUSTER_NAME"
echo "  - 节点 IP: $K3D_NODE_IP"
echo "  - NodePort: 30800"
echo "  - HAProxy 端口: 23080"
echo ""