#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# Load secrets
if [ -f "$ROOT_DIR/config/secrets.env" ]; then
	. "$ROOT_DIR/config/secrets.env"
fi

# Load configuration
if [ -f "$ROOT_DIR/config/clusters.env" ]; then
	. "$ROOT_DIR/config/clusters.env"
fi
: "${HAPROXY_HOST:=192.168.51.30}"
: "${HAPROXY_HTTP_PORT:=80}"
: "${HAPROXY_HTTPS_PORT:=443}"
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"
: "${PORTAINER_HTTP_PORT:=9000}"

# 使用 Portainer 在 infrastructure 网络中的 IP
PORTAINER_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "infrastructure"}}{{.IPAddress}}{{end}}' portainer-ce 2>/dev/null || echo "")
if [ -z "$PORTAINER_IP" ]; then
	echo "[ERROR] Cannot get Portainer IP from infrastructure network"
	exit 1
fi
PORTAINER_URL="http://${PORTAINER_IP}:${PORTAINER_HTTP_PORT}"

echo "[PORTAINER] Adding local Docker endpoint..."

# Authenticate and get JWT token
TOKEN=$(curl -sk -X POST "$PORTAINER_URL/api/auth" \
	-H "Content-Type: application/json" \
	-d "{\"username\":\"admin\",\"password\":\"$PORTAINER_ADMIN_PASSWORD\"}" |
	jq -r .jwt)

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
	echo "[ERROR] Failed to authenticate with Portainer"
	exit 1
fi

# Check if local endpoint already exists
EXISTING=$(curl -sk -X GET "$PORTAINER_URL/api/endpoints" \
	-H "Authorization: Bearer $TOKEN" |
	jq -r '.[] | select(.Name == "dockerhost") | .Id' || echo "")

if [ -n "$EXISTING" ]; then
	echo "[INFO] Local Docker endpoint already exists (ID: $EXISTING)"
	exit 0
fi

# Create local Docker endpoint (use form-urlencoded, not JSON)
RESPONSE=$(curl -sk -X POST "$PORTAINER_URL/api/endpoints" \
	-H "Authorization: Bearer $TOKEN" \
	-H "Content-Type: application/x-www-form-urlencoded" \
	-d "Name=dockerhost&EndpointCreationType=1&URL=unix:///var/run/docker.sock&GroupID=1")

ENDPOINT_ID=$(echo "$RESPONSE" | jq -r .Id 2>/dev/null || echo "")

if [ -n "$ENDPOINT_ID" ] && [ "$ENDPOINT_ID" != "null" ]; then
	echo "[SUCCESS] Local Docker endpoint created (ID: $ENDPOINT_ID)"
else
	echo "[ERROR] Failed to create local Docker endpoint"
	echo "Response: $RESPONSE"
	exit 1
fi
