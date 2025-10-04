#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -z "${HAPROXY_HOST:-}" ] && [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${HAPROXY_HOST:=127.0.0.1}"
: "${BASE_DOMAIN:=local}"

env_name="${1:-dev}"
report="$ROOT_DIR/docs/TEST_REPORT.md"
ts="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$ROOT_DIR/docs"

echo "# Smoke Test @ $ts" >> "$report"
echo "- HAPROXY_HOST: $HAPROXY_HOST" >> "$report"
echo "- BASE_DOMAIN: $BASE_DOMAIN" >> "$report"

echo "\n## Containers" >> "$report"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | sed -n '1,30p' >> "$report" || true

echo "\n## Curl" >> "$report"
echo "\n- Portainer HTTP (23380)" >> "$report"; { curl -sI "http://$HAPROXY_HOST:23380" | head -n1 || true; } | sed 's/^/  /' >> "$report"
echo "\n- Portainer HTTPS (23343)" >> "$report"; { curl -skI "https://$HAPROXY_HOST:23343" | head -n1 || true; } | sed 's/^/  /' >> "$report"
echo "\n- Ingress Host ($env_name.$BASE_DOMAIN via 23080)" >> "$report"; { curl -sI -H "Host: $env_name.$BASE_DOMAIN" "http://$HAPROXY_HOST:23080" | head -n1 || true; } | sed 's/^/  /' >> "$report"

echo "
## Portainer Endpoints" >> "$report"
if jwt=$("$ROOT_DIR"/scripts/portainer.sh api-login 2>/dev/null); then
  curl -skH "Authorization: Bearer $jwt" "https://127.0.0.1:23343/api/endpoints" |     (jq -r '.[] | "- \(.Id) \(.Name) type=\(.Type) url=\(.URL)"' 2>/dev/null || cat) >> "$report" || true
else
  echo "- login failed" >> "$report"
fi

echo "\n---\n" >> "$report"
echo "[smoke] report written to $report"
