#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Minimal validation of HAProxy routes and Portainer endpoints; optional Markdown report when TEST_REPORT_OUTPUT is set.
# Usage: scripts/smoke.sh <env> [service]
# Category: diagnostics
# Status: stable
# See also: scripts/haproxy_route.sh, scripts/portainer.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"

if [ -z "${HAPROXY_HOST:-}" ] && [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${HAPROXY_HOST:=127.0.0.1}"
: "${HAPROXY_HTTP_PORT:=80}"
: "${HAPROXY_HTTPS_PORT:=443}"
: "${BASE_DOMAIN:=local}"

env_name="${1:-dev}"
service_name="${2:-whoami}"
# 采用与 haproxy_route.sh 一致的域名规则：<service>.<env>.$BASE_DOMAIN
# 注意：不再使用 host_label()，以免 KINDLER_NS 后缀导致域名不匹配
host_env_label="$env_name"
host_fqdn="${service_name}.${host_env_label}.${BASE_DOMAIN}"
REPORT_PATH="${TEST_REPORT_OUTPUT:-}"
if [ -n "$REPORT_PATH" ]; then
  report="$REPORT_PATH"
  mkdir -p "$(dirname "$report")"
else
  report="/dev/null"
fi
ts="$(date '+%Y-%m-%d %H:%M:%S')"

ensure_no_proxy() {
  local host current
  for host in "$@"; do
    [ -n "$host" ] || continue
    current="${NO_PROXY:-${no_proxy:-}}"
    if [ -n "$current" ]; then
      case ",$current," in
        *",$host,"*) continue ;;
      esac
      current+=",$host"
    else
      current="$host"
    fi
    NO_PROXY="$current"
    no_proxy="$current"
  done
  export NO_PROXY no_proxy
}

ensure_no_proxy "$HAPROXY_HOST" "portainer.devops.${BASE_DOMAIN}" localhost 127.0.0.1

echo "# Smoke Test @ $ts" >> "$report"
echo "- HAPROXY_HOST: $HAPROXY_HOST" >> "$report"
echo "- BASE_DOMAIN: $BASE_DOMAIN" >> "$report"

echo "\n## Containers" >> "$report"
if [ "${DRY_RUN:-}" = "1" ]; then
  echo "(dry-run) skipped docker ps" >> "$report"
else
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | sed -n '1,30p' >> "$report" || true
fi

echo "\n## Curl" >> "$report"
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

status_portainer_http=""
status_portainer_https=""
status_ingress=""

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "\n- Portainer HTTP (${HAPROXY_HTTP_PORT})" >> "$report"
  echo "  (dry-run) skipped curl" >> "$report"
  echo "\n- Portainer HTTPS (${HAPROXY_HTTPS_PORT})" >> "$report"
  echo "  (dry-run) skipped curl" >> "$report"
  echo "\n- Ingress Host ($host_fqdn via ${HAPROXY_HTTP_PORT})" >> "$report"
  echo "  (dry-run) skipped curl" >> "$report"
else
  echo "\n- Portainer HTTP (${HAPROXY_HTTP_PORT})" >> "$report"
  status_portainer_http=$({ curl -sI -H "Host: portainer.devops.$BASE_DOMAIN" "$portainer_http_url" | head -n1 || true; } | awk '{print $2}')
  printf "  HTTP/1.x %s\n" "${status_portainer_http:-NA}" >> "$report"
  echo "\n- Portainer HTTPS (${HAPROXY_HTTPS_PORT})" >> "$report"
  status_portainer_https=$({ curl -skI -H "Host: portainer.devops.$BASE_DOMAIN" "$portainer_https_url" | head -n1 || true; } | awk '{print $2}')
  printf "  HTTPS %s\n" "${status_portainer_https:-NA}" >> "$report"
  echo "\n- Ingress Host ($host_fqdn via ${HAPROXY_HTTP_PORT})" >> "$report"
  status_ingress=$({ curl -sI -H "Host: $host_fqdn" "$service_http_url" | head -n1 || true; } | awk '{print $2}')
  printf "  HTTP/1.x %s\n" "${status_ingress:-NA}" >> "$report"
fi

echo "
## Portainer Endpoints" >> "$report"
if [ "${DRY_RUN:-}" = "1" ]; then
  echo "(dry-run) skipped API calls" >> "$report"
else
  if jwt=$("$ROOT_DIR"/scripts/portainer.sh api-login 2> /dev/null); then
    curl -skH "Host: portainer.devops.$BASE_DOMAIN" -H "Authorization: Bearer $jwt" "${portainer_https_url}/api/endpoints" | (jq -r '.[] | "- \(.Id) \(.Name) type=\(.Type) url=\(.URL)"' 2> /dev/null || cat) >> "$report" || true
  else
    echo "- login failed" >> "$report"
  fi
fi

echo "\n---\n" >> "$report"

# 简要结果输出（附加到 stdout 便于回归判读）
if [ -n "${status_portainer_http:-}" ] || [ -n "${status_portainer_https:-}" ] || [ -n "${status_ingress:-}" ]; then
  ok_http=0
  ok_https=0
  ok_ing=0
  # Portainer HTTP 301/302 视为通过（HTTP→HTTPS 跳转）
  if [ "${status_portainer_http:-}" = "301" ] || [ "${status_portainer_http:-}" = "302" ]; then ok_http=1; fi
  # Portainer HTTPS 200 视为通过
  if [ "${status_portainer_https:-}" = "200" ]; then ok_https=1; fi
  # Ingress 200 视为通过
  if [ "${status_ingress:-}" = "200" ]; then ok_ing=1; fi
  echo "[smoke] result env=$env_name http=$ok_http https=$ok_https ingress=$ok_ing (codes: ${status_portainer_http:-NA},${status_portainer_https:-NA},${status_ingress:-NA})"
fi
if [ -n "$REPORT_PATH" ]; then
  echo "[smoke] report written to $report"
else
  echo "[smoke] no TEST_REPORT_OUTPUT configured; see summary above"
fi
