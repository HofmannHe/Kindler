#!/usr/bin/env bash
# Portainer 登录功能测试（通过 HAProxy 域名）

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"

# 加载配置与密钥
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
if [ -f "$ROOT_DIR/config/secrets.env" ]; then . "$ROOT_DIR/config/secrets.env"; fi
BASE_DOMAIN="${BASE_DOMAIN:-192.168.51.30.sslip.io}"
HAPROXY_HOST="${HAPROXY_HOST:-192.168.51.30}"
PORTAINER_ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-admin123}"

echo "=========================================="
echo "Portainer Login Tests"
echo "=========================================="

# 1) 端到端登录（HTTPS，HAProxy 终止 TLS）
echo "[1/3] Portainer /api/auth via HTTPS"
auth_code=$(curl -k -s -o /dev/null -w "%{http_code}" -m 10 \
  -H "Host: portainer.devops.$BASE_DOMAIN" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$PORTAINER_ADMIN_PASSWORD\"}" \
  "https://$HAPROXY_HOST/api/auth" || echo "000")
assert_equals "200" "$auth_code" "Portainer /api/auth returns 200"

# 2) 返回 JWT 字段存在
echo "[2/3] Response includes JWT"
jwt=$(curl -k -s -m 10 \
  -H "Host: portainer.devops.$BASE_DOMAIN" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$PORTAINER_ADMIN_PASSWORD\"}" \
  "https://$HAPROXY_HOST/api/auth" | jq -r '.jwt' 2>/dev/null || echo "")
if [ -n "$jwt" ] && [ "$jwt" != "null" ]; then
  echo "  ✓ JWT token received"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ No JWT received (login failed)"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 3) 使用 JWT 访问 /api/endpoints（应返回 200）
echo "[3/3] Access /api/endpoints with JWT"
code=$(curl -k -s -o /dev/null -w "%{http_code}" -m 10 \
  -H "Host: portainer.devops.$BASE_DOMAIN" \
  -H "Authorization: Bearer $jwt" \
  "https://$HAPROXY_HOST/api/endpoints" || echo "000")
assert_equals "200" "$code" "Portainer /api/endpoints accessible with JWT"

print_summary

