#!/bin/bash
set -Eeuo pipefail

echo "=== Portainer Edge Agent 完整自动注册脚本 ==="

# 获取项目根目录
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# 配置参数
PORTAINER_URL="https://localhost:9443"
PORTAINER_USER="admin"
PORTAINER_PASS=$(grep PORTAINER_ADMIN_PASSWORD "$ROOT_DIR/config/secrets.env" | cut -d= -f2)
TIMESTAMP=$(date +%s)
ENVIRONMENT_NAME="k3d-edge-auto-$TIMESTAMP"
EDGE_AGENT_NAMESPACE="portainer-edge-new"
EDGE_AGENT_SERVICE="portainer-edge-new-svc"

# 函数：获取新的 JWT
get_jwt() {
    JWT=$(curl -k -X POST "$PORTAINER_URL/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$PORTAINER_USER\", \"password\": \"$PORTAINER_PASS\"}" \
        -s | jq -r '.jwt')

    if [[ "$JWT" == "null" || -z "$JWT" ]]; then
        echo "❌ 获取 JWT 失败"
        exit 1
    fi
    echo "✅ JWT 获取成功: ${JWT:0:50}..."
}

echo "步骤 1: 获取认证令牌..."
get_jwt

echo "步骤 2: 清理现有的 Edge 环境..."
# 列出并删除现有的 edge 环境
EXISTING_ENVS=$(curl -k -X GET "$PORTAINER_URL/api/endpoints" -H "Authorization: Bearer $JWT" -s)
EDGE_IDS=$(echo "$EXISTING_ENVS" | jq -r '.[] | select(.Type == 7) | .Id')

for edge_id in $EDGE_IDS; do
    echo "删除现有 Edge 环境 ID: $edge_id"
    curl -k -X DELETE "$PORTAINER_URL/api/endpoints/$edge_id" \
        -H "Authorization: Bearer $JWT" -s
done

echo "步骤 3: 创建新的 Edge Environment..."
EDGE_ENV_RESPONSE=$(curl -k -X POST "$PORTAINER_URL/api/endpoints" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "Name=$ENVIRONMENT_NAME&EndpointCreationType=4&URL=edge://placeholder&GroupID=1" \
    -s)

echo "环境创建响应: $EDGE_ENV_RESPONSE"

ENDPOINT_ID=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.Id')
EDGE_KEY=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.EdgeKey')

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]]; then
    echo "❌ Edge Environment 创建失败"
    exit 1
fi

echo "✅ Edge Environment 创建成功"
echo "   ID: $ENDPOINT_ID"
echo "   名称: $ENVIRONMENT_NAME"
echo "   Edge Key: ${EDGE_KEY:0:50}..."

echo "步骤 4: 检查 Edge Agent 状态..."
AGENT_POD=$(kubectl get pods -n "$EDGE_AGENT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "Edge Agent Pod: $AGENT_POD"

kubectl logs -n "$EDGE_AGENT_NAMESPACE" "$AGENT_POD" --tail=3

echo "步骤 5: 通过 Edge Agent API 配置 Edge Key..."
# 直接通过 pod 的 IP 访问，避免 port-forward 问题
AGENT_POD_IP=$(kubectl get pod -n "$EDGE_AGENT_NAMESPACE" "$AGENT_POD" -o jsonpath='{.status.podIP}')
echo "Agent Pod IP: $AGENT_POD_IP"

# 使用 kubectl exec 直接在 pod 中执行
echo "通过 kubectl exec 配置 Edge Key..."
AGENT_RESPONSE=$(kubectl exec -n "$EDGE_AGENT_NAMESPACE" "$AGENT_POD" -- \
    wget -qO- --method=POST \
    --header="Content-Type: application/json" \
    --body-data="{\"EdgeKey\": \"$EDGE_KEY\"}" \
    http://localhost:80/key)

echo "Agent 配置响应: $AGENT_RESPONSE"

echo "步骤 6: 验证注册状态..."
sleep 10

# 检查环境状态
get_jwt  # 重新获取 JWT 防止过期
ENV_STATUS=$(curl -k -X GET "$PORTAINER_URL/api/endpoints/$ENDPOINT_ID" \
    -H "Authorization: Bearer $JWT" \
    -s | jq -r '.Status')

echo "环境状态: $ENV_STATUS"
echo "状态说明: 1=连接正常, 2=连接异常"

if [[ "$ENV_STATUS" == "1" ]]; then
    echo "🎉 Edge Agent 自动注册成功！"
    echo "环境名称: $ENVIRONMENT_NAME"
    echo "环境 ID: $ENDPOINT_ID"
    echo "可以在 Portainer 界面查看 k3d 集群管理功能"
else
    echo "⚠️ Edge Agent 可能仍在连接中..."
    echo "请检查 Agent 日志："
    kubectl logs -n "$EDGE_AGENT_NAMESPACE" "$AGENT_POD" --tail=10
fi

echo "=== 完整自动注册流程结束 ==="