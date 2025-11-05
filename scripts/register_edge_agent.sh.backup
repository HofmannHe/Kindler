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

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "[DRY-RUN][EDGE] 计划为集群 ${CLUSTER_NAME}(${PROVIDER}) 执行 Edge Agent 注册:"
  echo "  - 登录 Portainer 获取 JWT"
  echo "  - 确认 Portainer 已连接到集群 Docker 网络"
  echo "  - 调用 /api/endpoints 创建 Edge Environment"
  echo "  - 使用 kubectl 应用 edge-agent.yaml (替换 EDGE_ID/EDGE_KEY)"
  echo "  - 等待 Edge Agent Pod 进入 Running 状态"
  exit 0
fi

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
: "${PORTAINER_HTTPS_PORT:=9443}"
: "${HAPROXY_HTTPS_PORT:=443}"
# 优先使用容器直连（HTTP:9000），减少对 DNS/HAProxy 的依赖
if [ -z "${PORTAINER_URL:-}" ]; then
  # 优先取 compose 的 infrastructure 网络 IP，避免多网络拼接
  PORTAINER_IP=$(docker inspect portainer-ce --format '{{with index .NetworkSettings.Networks "infrastructure"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)
  if [ -z "$PORTAINER_IP" ]; then
    # 回退：取第一个网络的 IP（通过 jq）
    if command -v jq >/dev/null 2>&1; then
      PORTAINER_IP=$(docker inspect portainer-ce 2>/dev/null | jq -r '.[0].NetworkSettings.Networks | to_entries[0].value.IPAddress // ""')
    else
      PORTAINER_IP=$(docker inspect portainer-ce --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
    fi
  fi
  if [ -n "$PORTAINER_IP" ]; then
    PORTAINER_URL="http://${PORTAINER_IP}:${PORTAINER_HTTP_PORT}"
  elif [ -n "${BASE_DOMAIN:-}" ]; then
    if [ "${HAPROXY_HTTPS_PORT}" = "443" ]; then
      PORTAINER_URL="https://portainer.devops.${BASE_DOMAIN}"
    else
      PORTAINER_URL="https://portainer.devops.${BASE_DOMAIN}:${HAPROXY_HTTPS_PORT}"
    fi
  elif [ -n "${HAPROXY_HOST:-}" ]; then
    if [ "${HAPROXY_HTTPS_PORT}" = "443" ]; then
      PORTAINER_URL="https://${HAPROXY_HOST}"
    else
      PORTAINER_URL="https://${HAPROXY_HOST}:${HAPROXY_HTTPS_PORT}"
    fi
  else
    PORTAINER_URL="https://127.0.0.1:${PORTAINER_HTTPS_PORT}"
  fi
fi

# 获取 JWT
echo "[EDGE] Authenticating with Portainer at $PORTAINER_URL..."
j=; for i in 1 2 3 4 5; do
  j=$(curl -sk -m 8 -X POST "$PORTAINER_URL/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"admin\", \"password\": \"$PORTAINER_ADMIN_PASSWORD\"}" | jq -r '.jwt' 2>/dev/null || true)
  [ -n "$j" ] && [ "$j" != "null" ] && break
  sleep $((i*2))
done
JWT="$j"

if [ -z "$JWT" ] || [ "$JWT" = "null" ]; then
	echo "[EDGE] ERROR: Failed to authenticate with Portainer" >&2
	exit 1
fi

# 构造 Edge Environment 名称
EP_NAME=$(echo "$CLUSTER_NAME" | sed 's/-//g') # 移除连字符，例如 dev-k3d -> devk3d

echo "[EDGE] Creating Edge Environment: $EP_NAME"

# 获取 Portainer 在集群网络中的 IP
if [ "$PROVIDER" = "k3d" ]; then
	cluster_node="k3d-${CLUSTER_NAME}-server-0"
else
	cluster_node="${CLUSTER_NAME}-control-plane"
fi

NETWORK_NAME=$(docker inspect "$cluster_node" 2>/dev/null |
	jq -r '.[0].NetworkSettings.Networks | keys[0]' 2>/dev/null || echo "")

if [ -z "$NETWORK_NAME" ] || [ "$NETWORK_NAME" = "null" ]; then
	if [ "$PROVIDER" = "k3d" ]; then
		NETWORK_NAME="k3d-${CLUSTER_NAME}"
	else
		NETWORK_NAME="kind"
	fi
fi

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
    # 处理名称已存在的幂等场景
    if echo "$EDGE_ENV_RESPONSE" | grep -qi "Name is not unique"; then
      echo "[EDGE] Edge Environment already exists: $EP_NAME (idempotent)"
      # 查询已存在的 Endpoint ID
      EXISTING_JSON=$(curl -sk -H "Authorization: Bearer $JWT" "$PORTAINER_URL/api/endpoints")
      ENDPOINT_ID=$(echo "$EXISTING_JSON" | jq -r '.[] | select(.Name=="'$EP_NAME'") | .Id' | head -1)
      if [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "null" ]; then
        echo "[EDGE] WARN: cannot resolve existing endpoint id for $EP_NAME, continue"
      fi
    else
      echo "[EDGE] ERROR: Failed to create Edge Environment" >&2
      echo "$EDGE_ENV_RESPONSE" | jq '.' >&2
      exit 1
    fi
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
	"$ROOT_DIR/manifests/portainer/edge-agent.yaml" |
	kubectl --context "$CTX" apply -f -

echo "[EDGE] Waiting for Edge Agent to be Running..."
# wait up to ~180s for Running
for i in $(seq 1 90); do
  POD_STATUS=$(kubectl --context "$CTX" get pods -n portainer-edge -l app=portainer-edge-agent \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$POD_STATUS" = "Running" ]; then
    break
  fi
  sleep 2
done
echo "[EDGE] Edge Agent Pod status: ${POD_STATUS:-Unknown}"
echo "[EDGE] Edge Agent deployed"

# Generalized retry: preload image to cluster and retry if not Running
. "$ROOT_DIR/scripts/lib.sh"
ensure_pod_running_with_preload "$CTX" portainer-edge 'app=portainer-edge-agent' "$PROVIDER" "$CLUSTER_NAME" 'portainer/agent:latest' 180 || true

echo ""
echo "[EDGE] Registration complete!"
echo "[EDGE] Check Portainer UI: $PORTAINER_URL"
