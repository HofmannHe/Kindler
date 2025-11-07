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
EP_NAME="$CLUSTER_NAME" # 保留原始集群名（含连字符）

echo "[EDGE] Creating Edge Environment: $EP_NAME"

# 使用 HAProxy 作为统一入口，Edge Agent 通过 HAProxy 访问 Portainer
# 使用 host.docker.internal 让所有集群都能访问 HAProxy（通过宿主机）
HAPROXY_HOST="${HAPROXY_HOST:-host.docker.internal}"
HAPROXY_API_PORT="${HAPROXY_HTTP_PORT:-80}"

echo "[EDGE] Using HAProxy host: $HAPROXY_HOST:$HAPROXY_API_PORT (accessible from all clusters)"
echo "[EDGE] Edge Agent will connect to Portainer via HAProxy (port $HAPROXY_API_PORT for API, port 8000 for WebSocket)"

# 创建 Edge Environment（Edge Agent 通过 HAProxy 访问 Portainer）
# HAProxy 80 端口处理 API 请求，8000 端口处理 WebSocket 连接
EDGE_ENV_RESPONSE=$(curl -sk -X POST "$PORTAINER_URL/api/endpoints" \
	-H "Authorization: Bearer $JWT" \
	-H "Content-Type: application/x-www-form-urlencoded" \
	-d "Name=$EP_NAME&EndpointCreationType=4&URL=http://$HAPROXY_HOST:$HAPROXY_API_PORT&GroupID=1")

ENDPOINT_ID=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.Id')
EDGE_KEY=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.EdgeKey')

if [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "null" ]; then
    # 处理名称已存在的幂等场景
    if echo "$EDGE_ENV_RESPONSE" | grep -qi "Name is not unique"; then
      echo "[EDGE] Edge Environment already exists: $EP_NAME (idempotent)"
      # 查询已存在的 Endpoint ID 和 Edge Key
      EXISTING_JSON=$(curl -sk -H "Authorization: Bearer $JWT" "$PORTAINER_URL/api/endpoints")
      ENDPOINT_ID=$(echo "$EXISTING_JSON" | jq -r '.[] | select(.Name=="'$EP_NAME'") | .Id' | head -1)
      EDGE_KEY=$(echo "$EXISTING_JSON" | jq -r '.[] | select(.Name=="'$EP_NAME'") | .EdgeKey' | head -1)
      if [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "null" ]; then
        echo "[EDGE] WARN: cannot resolve existing endpoint id for $EP_NAME, continue"
      fi
      if [ -z "$EDGE_KEY" ] || [ "$EDGE_KEY" = "null" ]; then
        echo "[EDGE] WARN: cannot resolve existing edge key for $EP_NAME, will use null"
        EDGE_KEY="null"
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

# GitOps 兼容方案：创建 Secret，Edge Agent 由 ArgoCD 部署
echo "[EDGE] Creating Edge Agent credentials Secret (GitOps-compliant)..."

CTX_PREFIX=$([ "$PROVIDER" = "k3d" ] && echo k3d || echo kind)
CTX="$CTX_PREFIX-$CLUSTER_NAME"

# Create namespace
kubectl --context "$CTX" create namespace portainer-edge --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null 2>&1

# Create Secret with Edge credentials (这是运行时动态值，不能存储在 Git)
kubectl --context "$CTX" create secret generic portainer-edge-creds \
	--namespace=portainer-edge \
	--from-literal=edge-id="$ENDPOINT_ID" \
	--from-literal=edge-key="$EDGE_KEY" \
	--dry-run=client -o yaml | kubectl --context "$CTX" apply -f -

echo "[EDGE] Credentials Secret created"

# 直接部署 Edge Agent（临时方案，最终应该由 ArgoCD 管理）
# 为了快速验证，先直接部署，后续可以迁移到 GitOps
echo "[EDGE] Deploying Edge Agent (direct deployment for immediate availability)..."

# k3d和kind集群都运行在容器中，无法访问宿主机Docker socket
# Edge Agent只使用Kubernetes API管理（这是Kubernetes集群的标准方式）
if true; then
  echo "[EDGE] Deploying Edge Agent (Kubernetes-only mode)"
  cat <<EOF | kubectl --context "$CTX" apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: portainer-edge-agent
  namespace: portainer-edge
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: portainer-edge-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: portainer-edge-agent
  namespace: portainer-edge
---
apiVersion: v1
kind: Service
metadata:
  name: portainer-edge-agent
  namespace: portainer-edge
spec:
  type: ClusterIP
  selector:
    app: portainer-edge-agent
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: s-portainer-agent-headless
  namespace: portainer-edge
spec:
  clusterIP: None
  selector:
    app: portainer-edge-agent
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portainer-edge-agent
  namespace: portainer-edge
  labels:
    app: portainer-edge-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: portainer-edge-agent
  template:
    metadata:
      labels:
        app: portainer-edge-agent
    spec:
      serviceAccountName: portainer-edge-agent
      containers:
      - name: portainer-edge-agent
        image: portainer/agent:latest
        imagePullPolicy: IfNotPresent
        env:
        - name: EDGE
          value: "1"
        - name: EDGE_ID
          valueFrom:
            secretKeyRef:
              name: portainer-edge-creds
              key: edge-id
        - name: EDGE_KEY
          valueFrom:
            secretKeyRef:
              name: portainer-edge-creds
              key: edge-key
        - name: EDGE_INSECURE_POLL
          value: "1"
        - name: CAP_HOST_MANAGEMENT
          value: "0"
        - name: KUBERNETES_POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        ports:
        - containerPort: 80
          protocol: TCP
EOF
fi

echo "[EDGE] Waiting for Edge Agent to be ready (max 300s = 5min)..."
# Generalized retry: preload image to cluster and retry if not Running
. "$ROOT_DIR/scripts/lib.sh"
ensure_pod_running_with_preload "$CTX" portainer-edge 'app=portainer-edge-agent' "$PROVIDER" "$CLUSTER_NAME" 'portainer/agent:latest' 300 || {
	echo "[ERROR] Edge Agent pod failed to start"
	kubectl --context "$CTX" get pods -n portainer-edge
	kubectl --context "$CTX" describe pods -n portainer-edge -l app=portainer-edge-agent | tail -30
	exit 1
}

echo ""
echo "[EDGE] Registration complete!"
echo "[EDGE] Check Portainer UI: $PORTAINER_URL"
