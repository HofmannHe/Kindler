#!/bin/bash
set -euo pipefail

echo "[DEPRECATED] register_portainer_agents.sh 已弃用，请改用 scripts/register_edge_agent.sh 或 scripts/portainer.sh add-endpoint。" >&2

ROOT_DIR="$(dirname "$0")/.."
source "$ROOT_DIR/config/secrets.env"
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${PORTAINER_HTTPS_PORT:=9443}"

# 登录 Portainer
echo "=== 登录 Portainer ==="
TOKEN=$(curl -sk -X POST "https://localhost:${PORTAINER_HTTPS_PORT}/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\":\"admin\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}" | jq -r '.jwt')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "❌ 登录失败"
  exit 1
fi

echo "✅ 登录成功"
echo ""

# 注册 KIND 集群
echo "=== 注册 KIND 集群 ==="
for cluster in dev uat prod; do
  NODE_IP=$(docker inspect ${cluster}-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
  NODE_PORT=$(kubectl --context=kind-$cluster get svc portainer-agent -n portainer -o jsonpath='{.spec.ports[0].nodePort}')

  echo "注册 kind-$cluster ($NODE_IP:$NODE_PORT)..."
  RESULT=$(curl -sk -X POST "https://localhost:${PORTAINER_HTTPS_PORT}/api/endpoints" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"Name\": \"kind-$cluster\",
      \"EndpointCreationType\": 2,
      \"URL\": \"tcp://$NODE_IP:$NODE_PORT\"
    }")

  if echo "$RESULT" | jq -e '.Id' > /dev/null 2>&1; then
    echo "  ✅ 成功 (ID: $(echo $RESULT | jq -r '.Id'))"
  else
    ERROR=$(echo "$RESULT" | jq -r '.message // .details // "Unknown error"')
    echo "  ⚠️  $ERROR"
  fi
done

echo ""
echo "=== 注册 K3D 集群 ==="
for cluster in dev-k3d uat-k3d prod-k3d; do
  NODE_IP=$(docker inspect k3d-${cluster}-server-0 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
  NODE_PORT=$(kubectl --context=k3d-$cluster get svc portainer-agent -n portainer -o jsonpath='{.spec.ports[0].nodePort}')

  echo "注册 $cluster ($NODE_IP:$NODE_PORT)..."
  RESULT=$(curl -sk -X POST "https://localhost:${PORTAINER_HTTPS_PORT}/api/endpoints" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"Name\": \"$cluster\",
      \"EndpointCreationType\": 2,
      \"URL\": \"tcp://$NODE_IP:$NODE_PORT\"
    }")

  if echo "$RESULT" | jq -e '.Id' > /dev/null 2>&1; then
    echo "  ✅ 成功 (ID: $(echo $RESULT | jq -r '.Id'))"
  else
    ERROR=$(echo "$RESULT" | jq -r '.message // .details // "Unknown error"')
    echo "  ⚠️  $ERROR"
  fi
done

echo ""
echo "=== 查看所有已注册环境 ==="
curl -sk -H "Authorization: Bearer $TOKEN" "https://localhost:${PORTAINER_HTTPS_PORT}/api/endpoints" | \
  jq -r '.[] | "  - \(.Name) (ID: \(.Id), Type: \(.Type))"'
