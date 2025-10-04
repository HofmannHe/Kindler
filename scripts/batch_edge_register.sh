#!/bin/bash
set -Eeuo pipefail

echo "=========================================="
echo "批量部署并注册 Portainer Edge Agent"
echo "=========================================="

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PORTAINER_URL="https://localhost:9443"
PORTAINER_USER="admin"
PORTAINER_PASS=$(grep PORTAINER_ADMIN_PASSWORD "$ROOT_DIR/config/secrets.env" | cut -d= -f2)

# 集群列表
CLUSTERS=(
  "kind-dev:kind"
  "kind-uat:kind"
  "kind-prod:kind"
  "k3d-dev-k3d:k3d"
  "k3d-uat-k3d:k3d"
  "k3d-prod-k3d:k3d"
)

# 函数：获取 JWT
get_jwt() {
    JWT=$(curl -k -X POST "$PORTAINER_URL/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$PORTAINER_USER\", \"password\": \"$PORTAINER_PASS\"}" \
        -s | jq -r '.jwt')

    if [[ "$JWT" == "null" || -z "$JWT" ]]; then
        echo "❌ JWT 获取失败"
        exit 1
    fi
}

# 函数：为单个集群部署并注册 Edge Agent
register_cluster() {
    local CLUSTER_CTX="$1"
    local CLUSTER_TYPE="$2"
    local CLUSTER_NAME=$(echo "$CLUSTER_CTX" | sed 's/^kind-//; s/^k3d-//')

    echo ""
    echo "=========================================="
    echo "处理集群: $CLUSTER_CTX ($CLUSTER_TYPE)"
    echo "=========================================="

    # 步骤 1: 创建 Edge Environment
    echo "步骤 1: 在 Portainer 中创建 Edge Environment..."
    get_jwt

    EDGE_ENV_RESPONSE=$(curl -k -X POST "$PORTAINER_URL/api/endpoints" \
        -H "Authorization: Bearer $JWT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "Name=$CLUSTER_NAME&EndpointCreationType=4&URL=edge://placeholder&GroupID=1" \
        -s)

    ENDPOINT_ID=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.Id')
    EDGE_KEY=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.EdgeKey')

    if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]]; then
        echo "❌ Edge Environment 创建失败: $EDGE_ENV_RESPONSE"
        return 1
    fi

    echo "✅ Edge Environment 创建成功 (ID: $ENDPOINT_ID)"

    # 步骤 2: 部署 Edge Agent manifest
    echo "步骤 2: 部署 Edge Agent 到集群..."

    # 创建临时 manifest 替换 EDGE_ID 和 EDGE_KEY
    cat > /tmp/edge-agent-$CLUSTER_NAME.yaml << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: portainer
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: portainer-edge-agent
  namespace: portainer
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
  namespace: portainer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portainer-edge-agent
  namespace: portainer
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
      - name: agent
        image: portainer/agent:latest
        imagePullPolicy: IfNotPresent
        env:
        - name: EDGE
          value: "1"
        - name: EDGE_ID
          value: "$ENDPOINT_ID"
        - name: EDGE_KEY
          value: "$EDGE_KEY"
        - name: EDGE_INSECUREPOLL
          value: "1"
        - name: CAP_HOST_MANAGEMENT
          value: "1"
        - name: EDGE_SERVER_ADDRESS
          value: "host.k3d.internal:9443"
        - name: LOG_LEVEL
          value: INFO
        ports:
        - containerPort: 80
          protocol: TCP
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        emptyDir: {}
EOF

    kubectl --context=$CLUSTER_CTX apply -f /tmp/edge-agent-$CLUSTER_NAME.yaml

    # 步骤 3: 导入镜像
    echo "步骤 3: 导入 portainer/agent 镜像..."
    if [[ "$CLUSTER_TYPE" == "kind" ]]; then
        CLUSTER_SHORT=$(echo "$CLUSTER_CTX" | sed 's/^kind-//')
        docker save portainer/agent:latest | docker exec -i ${CLUSTER_SHORT}-control-plane ctr -n k8s.io images import - 2>/dev/null || true
    else
        CLUSTER_SHORT=$(echo "$CLUSTER_CTX" | sed 's/^k3d-//')
        k3d image import portainer/agent:latest -c $CLUSTER_SHORT 2>/dev/null || true
    fi

    # 步骤 4: 等待 pod 就绪
    echo "步骤 4: 等待 Edge Agent 启动..."
    kubectl --context=$CLUSTER_CTX wait --for=condition=ready pod \
        -l app=portainer-edge-agent -n portainer --timeout=60s 2>/dev/null || true

    sleep 5

    # 步骤 5: 验证状态
    echo "步骤 5: 验证连接状态..."
    get_jwt
    ENV_STATUS=$(curl -k -X GET "$PORTAINER_URL/api/endpoints/$ENDPOINT_ID" \
        -H "Authorization: Bearer $JWT" \
        -s | jq -r '.Status')

    if [[ "$ENV_STATUS" == "1" ]]; then
        echo "✅ $CLUSTER_NAME 注册成功 (状态: $ENV_STATUS)"
    else
        echo "⚠️  $CLUSTER_NAME 连接中... (状态: $ENV_STATUS)"
    fi

    rm -f /tmp/edge-agent-$CLUSTER_NAME.yaml
}

# 主流程：批量处理所有集群
echo ""
echo "开始批量注册 ${#CLUSTERS[@]} 个集群..."
echo ""

for cluster_info in "${CLUSTERS[@]}"; do
    IFS=':' read -r ctx type <<< "$cluster_info"
    register_cluster "$ctx" "$type"
done

echo ""
echo "=========================================="
echo "批量注册完成！"
echo "=========================================="

# 最终验证
echo ""
echo "最终验证 - 所有已注册环境:"
get_jwt
curl -k -H "Authorization: Bearer $JWT" "$PORTAINER_URL/api/endpoints" -s | \
    jq -r '.[] | "  [\(.Id)] \(.Name) - 状态: \(.Status) - 类型: \(if .Type == 7 then "Edge Agent" else "其他" end)"'

echo ""
echo "✅ 所有集群处理完成！请在 Portainer UI 中查看: $PORTAINER_URL"