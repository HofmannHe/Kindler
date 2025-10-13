#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

if [ -z "${HAPROXY_HOST:-}" ] && [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${HAPROXY_HOST:=127.0.0.1}"
: "${HAPROXY_HTTP_PORT:=80}"
: "${HAPROXY_HTTPS_PORT:=443}"
: "${BASE_DOMAIN:=local}"

env_name="${1:-dev}"
service_name="${2:-whoami}"
# 使用 host_label 确保在 KINDLER_NS 下追加命名空间后缀（如 devns）
host_env_label="$(host_label "$env_name")"
host_fqdn="${service_name}.${host_env_label}.${BASE_DOMAIN}"
report="$ROOT_DIR/docs/TEST_REPORT.md"
ts="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$ROOT_DIR/docs"

echo "# Smoke Test @ $ts" >>"$report"
echo "- HAPROXY_HOST: $HAPROXY_HOST" >>"$report"
echo "- BASE_DOMAIN: $BASE_DOMAIN" >>"$report"

echo "\n## Containers" >>"$report"
if [ "${DRY_RUN:-}" = "1" ]; then
  echo "(dry-run) skipped docker ps" >>"$report"
else
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | sed -n '1,30p' >>"$report" || true
fi

echo "\n## Curl" >>"$report"
portainer_http_url="http://$HAPROXY_HOST"
if [ "$HAPROXY_HTTP_PORT" != "80" ]; then
	portainer_http_url="${portainer_http_url}:$HAPROXY_HTTP_PORT"
fi
portainer_https_url="https://$HAPROXY_HOST"
if [ "$HAPROXY_HTTPS_PORT" != "443" ]; then
	portainer_https_url="${portainer_https_url}:$HAPROXY_HTTPS_PORT"
fi
service_http_url="http://$HAPROXY_HOST"
if [ "$HAPROXY_HTTP_PORT" != "80" ]; then
	service_http_url="${service_http_url}:$HAPROXY_HTTP_PORT"
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "\n- Portainer HTTP (${HAPROXY_HTTP_PORT})" >>"$report"
  echo "  (dry-run) skipped curl" >>"$report"
  echo "\n- Portainer HTTPS (${HAPROXY_HTTPS_PORT})" >>"$report"
  echo "  (dry-run) skipped curl" >>"$report"
  echo "\n- Ingress Host ($host_fqdn via ${HAPROXY_HTTP_PORT})" >>"$report"
  echo "  (dry-run) skipped curl" >>"$report"
else
  echo "\n- Portainer HTTP (${HAPROXY_HTTP_PORT})" >>"$report"
  { curl -sI -H "Host: portainer.devops.$BASE_DOMAIN" "$portainer_http_url" | head -n1 || true; } | sed 's/^/  /' >>"$report"
  echo "\n- Portainer HTTPS (${HAPROXY_HTTPS_PORT})" >>"$report"
  { curl -skI -H "Host: portainer.devops.$BASE_DOMAIN" "$portainer_https_url" | head -n1 || true; } | sed 's/^/  /' >>"$report"
  echo "\n- Ingress Host ($host_fqdn via ${HAPROXY_HTTP_PORT})" >>"$report"
  { curl -sI -H "Host: $host_fqdn" "$service_http_url" | head -n1 || true; } | sed 's/^/  /' >>"$report"
fi

echo "
## Portainer Endpoints" >>"$report"
if [ "${DRY_RUN:-}" = "1" ]; then
  echo "(dry-run) skipped API calls" >>"$report"
else
  if jwt=$("$ROOT_DIR"/scripts/portainer.sh api-login 2>/dev/null); then
    curl -skH "Authorization: Bearer $jwt" "${portainer_https_url}/api/endpoints" | (jq -r '.[] | "- \(.Id) \(.Name) type=\(.Type) url=\(.URL)"' 2>/dev/null || cat) >>"$report" || true
  else
    echo "- login failed" >>"$report"
  fi
fi

echo "\n---\n" >>"$report"
echo "[smoke] report written to $report"
