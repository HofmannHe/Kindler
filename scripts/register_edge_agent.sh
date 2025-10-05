#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
  echo "Usage: $0 <cluster-name> <provider>" >&2
  echo "  provider: kind or k3d" >&2
  exit 1
}

[ $# -lt 2 ] && usage

CLUSTER_NAME="$1"
PROVIDER="$2"

# 加载密钥
if [ -f "$ROOT_DIR/config/secrets.env" ]; then
  . "$ROOT_DIR/config/secrets.env"
fi
: "${PORTAINER_ADMIN_PASSWORD:=admin123}"

# 加载配置
if [ -f "$ROOT_DIR/config/clusters.env" ]; then
  . "$ROOT_DIR/config/clusters.env"
fi
: "${PORTAINER_HTTP_PORT:=9000}"
PORTAINER_URL="${PORTAINER_URL:-https://192.168.51.30:23343}"

# 获取 JWT
echo "[EDGE] Authenticating with Portainer..."
JWT=$(curl -sk -X POST "$PORTAINER_URL/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"admin\", \"password\": \"$PORTAINER_ADMIN_PASSWORD\"}" | jq -r '.jwt')

if [ -z "$JWT" ] || [ "$JWT" = "null" ]; then
  echo "[EDGE] ERROR: Failed to authenticate with Portainer" >&2
  exit 1
fi

# 构造 Edge Environment 名称
EP_NAME=$(echo "$CLUSTER_NAME" | sed 's/-//g')  # 移除连字符，例如 dev-k3d -> devk3d

echo "[EDGE] Creating Edge Environment: $EP_NAME"

# 获取 Portainer 在集群网络中的 IP
NETWORK_NAME="${PROVIDER}-${CLUSTER_NAME}"
PORTAINER_IP=$(docker inspect portainer-ce | jq -r ".[0].NetworkSettings.Networks[\"$NETWORK_NAME\"].IPAddress" 2>/dev/null || true)

# 如果 Portainer 还未连接到该网络，先连接
if [ -z "$PORTAINER_IP" ] || [ "$PORTAINER_IP" = "null" ]; then
  echo "[EDGE] Connecting Portainer to $NETWORK_NAME network..."
  docker network connect "$NETWORK_NAME" portainer-ce 2>/dev/null || true
  sleep 2
  PORTAINER_IP=$(docker inspect portainer-ce | jq -r ".[0].NetworkSettings.Networks[\"$NETWORK_NAME\"].IPAddress" 2>/dev/null || true)
fi

if [ -z "$PORTAINER_IP" ] || [ "$PORTAINER_IP" = "null" ]; then
  echo "[EDGE] ERROR: Failed to get Portainer IP in $NETWORK_NAME network" >&2
  exit 1
fi

echo "[EDGE] Portainer IP in cluster network: $PORTAINER_IP"

# 创建 Edge Environment（使用 HTTP 避免 TLS 证书问题）
EDGE_ENV_RESPONSE=$(curl -sk -X POST "$PORTAINER_URL/api/endpoints" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "Name=$EP_NAME&EndpointCreationType=4&URL=http://$PORTAINER_IP:${PORTAINER_HTTP_PORT}&GroupID=1")

ENDPOINT_ID=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.Id')
EDGE_KEY=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.EdgeKey')

if [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "null" ]; then
  echo "[EDGE] ERROR: Failed to create Edge Environment" >&2
  echo "$EDGE_ENV_RESPONSE" | jq '.' >&2
  exit 1
fi

echo "[EDGE] Edge Environment created successfully"
echo "[EDGE]   ID: $ENDPOINT_ID"
echo "[EDGE]   Name: $EP_NAME"

# 部署 Edge Agent
echo "[EDGE] Deploying Edge Agent to cluster..."

CTX_PREFIX=$([ "$PROVIDER" = "k3d" ] && echo k3d || echo kind)
CTX="$CTX_PREFIX-$CLUSTER_NAME"

# 使用 sed 替换 YAML 中的占位符并应用
sed -e "s/EDGE_ID_PLACEHOLDER/$ENDPOINT_ID/g" \
    -e "s/EDGE_KEY_PLACEHOLDER/$EDGE_KEY/g" \
    "$ROOT_DIR/manifests/portainer/edge-agent.yaml" | \
  kubectl --context "$CTX" apply -f -

echo "[EDGE] Waiting for Edge Agent to start..."
kubectl --context "$CTX" wait --for=condition=ready pod -l app=portainer-edge-agent -n portainer-edge --timeout=60s 2>/dev/null || true

# 检查 Pod 状态
POD_STATUS=$(kubectl --context "$CTX" get pods -n portainer-edge -l app=portainer-edge-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "[EDGE] Edge Agent Pod status: $POD_STATUS"

if [ "$POD_STATUS" = "Running" ]; then
  echo "[EDGE] ✅ Edge Agent deployed successfully"
else
  echo "[EDGE] ⚠️  Edge Agent Pod not Running yet, checking logs..."
  kubectl --context "$CTX" logs -n portainer-edge -l app=portainer-edge-agent --tail=10 2>/dev/null || true
fi

echo ""
echo "[EDGE] Registration complete!"
echo "[EDGE] Check Portainer UI: $PORTAINER_URL"
