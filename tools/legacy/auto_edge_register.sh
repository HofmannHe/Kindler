#!/bin/bash
set -Eeuo pipefail

echo "[DEPRECATED] auto_edge_register.sh 已弃用，请改用 scripts/register_edge_agent.sh --edge 或 tools/maintenance/batch_create_envs.sh。" >&2
echo "=== Portainer Edge Agent 全自动注册 ==="

# 配置
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${PORTAINER_HTTPS_PORT:=9443}"
PORTAINER_URL="https://localhost:${PORTAINER_HTTPS_PORT}"
PORTAINER_USER="admin"
PORTAINER_PASS=$(grep PORTAINER_ADMIN_PASSWORD "$ROOT_DIR/config/secrets.env" | cut -d= -f2)
NAMESPACE="portainer"
CLUSTER_NAME="${1:-k3d-cluster}"
ENVIRONMENT_NAME="${CLUSTER_NAME}-$(date +%s)"

# 获取 JWT
get_jwt() {
    JWT=$(curl -k -X POST "$PORTAINER_URL/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$PORTAINER_USER\", \"password\": \"$PORTAINER_PASS\"}" \
        -s | jq -r '.jwt')

    if [[ "$JWT" == "null" || -z "$JWT" ]]; then
        echo "❌ JWT 获取失败"
        exit 1
    fi
    echo "✅ JWT 获取成功"
}

echo ""
echo "步骤 1: 部署 Edge Agent..."
kubectl apply -f "$ROOT_DIR/manifests/portainer/edge-agent.yaml"

echo ""
echo "步骤 2: 等待 Agent 启动 (最多等待 2 分钟)..."
if kubectl wait --for=condition=ready pod -l app=portainer-edge-agent -n "$NAMESPACE" --timeout=120s; then
    echo "✅ Agent Pod 已就绪"
else
    echo "❌ Agent Pod 启动超时，检查状态:"
    kubectl get pods -n "$NAMESPACE"
    kubectl describe pod -l app=portainer-edge-agent -n "$NAMESPACE" | tail -15
    exit 1
fi

echo ""
echo "步骤 3: 获取认证并创建 Edge Environment..."
get_jwt

# 创建新的 Edge Environment
echo "创建新的 Edge Environment..."
EDGE_ENV=$(curl -k -X POST "$PORTAINER_URL/api/endpoints" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "Name=$ENVIRONMENT_NAME&EndpointCreationType=4&URL=edge://k3d&GroupID=1" \
    -s)

ENDPOINT_ID=$(echo "$EDGE_ENV" | jq -r '.Id')
EDGE_KEY=$(echo "$EDGE_ENV" | jq -r '.EdgeKey')

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]]; then
    echo "❌ Edge Environment 创建失败: $EDGE_ENV"
    exit 1
fi

echo "✅ Edge Environment 创建成功"
echo "   环境 ID: $ENDPOINT_ID"
echo "   Edge Key: ${EDGE_KEY:0:20}..."

echo ""
echo "步骤 4: 配置 Edge Agent (注入 EDGE_KEY)..."
kubectl set env deployment/portainer-edge-agent -n "$NAMESPACE" \
    EDGE_KEY="$EDGE_KEY" \
    EDGE_SERVER_ADDRESS="host.k3d.internal:${PORTAINER_HTTPS_PORT}"

echo ""
echo "步骤 5: 等待 Agent 重启并连接..."
kubectl rollout status deployment/portainer-edge-agent -n "$NAMESPACE" --timeout=60s
sleep 15

echo ""
echo "步骤 6: 验证连接状态..."
get_jwt
ENV_STATUS=$(curl -k -X GET "$PORTAINER_URL/api/endpoints/$ENDPOINT_ID" \
    -H "Authorization: Bearer $JWT" -s | jq -r '.Status')

echo "环境状态码: $ENV_STATUS"
echo "  (1=已连接, 2=未连接, 3=心跳丢失)"

if [[ "$ENV_STATUS" == "1" ]]; then
    echo ""
    echo "🎉 Edge Agent 全自动注册成功！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   环境名称: $ENVIRONMENT_NAME"
    echo "   环境 ID: $ENDPOINT_ID"
    echo "   访问地址: $PORTAINER_URL"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo ""
    echo "⚠️ 连接状态异常，检查 Agent 日志:"
    kubectl logs -l app=portainer-edge-agent -n "$NAMESPACE" --tail=20
fi

echo ""
echo "=== 注册流程完成 ==="
