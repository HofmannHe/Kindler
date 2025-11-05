#!/usr/bin/env bash
# Declarative WebUI API smoke test (lightweight, no heavy infra assumptions)

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEBUI_URL="${WEBUI_URL:-http://kindler.devops.192.168.51.30.sslip.io}"

echo "[SMOKE] Declarative WebUI API"
echo "  WebUI: $WEBUI_URL"

http() {
  local m="$1"; shift
  local p="$1"; shift
  local d="${1:-}"
  if [ -n "$d" ]; then
    curl -s -w "\n%{http_code}" -H 'Content-Type: application/json' -X "$m" "$WEBUI_URL$p" -d "$d" -m 10
  else
    curl -s -w "\n%{http_code}" -X "$m" "$WEBUI_URL$p" -m 10
  fi
}

echo "[CHECK] WebUI reachable"
if ! timeout 5 curl -sf "$WEBUI_URL/api/health" >/dev/null 2>&1; then
  echo "  ⚠ WebUI not reachable; ensure backend is up. Skipping."
  exit 2
fi
echo "  ✓ OK"

echo "[TEST] DELETE /api/clusters/devops protected (403)"
resp=$(http DELETE "/api/clusters/devops")
code=$(echo "$resp" | tail -n1)
if [ "$code" != "403" ]; then
  echo "  ✗ Expected 403, got $code"
  exit 1
fi
echo "  ✓ OK"

tmp="smoke-$(date +%s)"
payload="{\"name\":\"$tmp\",\"provider\":\"k3d\"}"

echo "[TEST] POST /api/clusters (declarative create)"
resp=$(http POST "/api/clusters" "$payload")
code=$(echo "$resp" | tail -n1)
body=$(echo "$resp" | head -n -1)
if [ "$code" != "202" ]; then
  echo "  ✗ Expected 202, got $code; body: $body"
  exit 1
fi
echo "  ✓ Accepted (task stub)"

echo "[TEST] GET /api/clusters/$tmp contains reconcile fields"
sleep 1
resp=$(http GET "/api/clusters/$tmp")
code=$(echo "$resp" | tail -n1)
body=$(echo "$resp" | head -n -1)
if [ "$code" != "200" ]; then
  echo "  ✗ Expected 200, got $code; body: $body"
  exit 1
fi
desired=$(echo "$body" | jq -r '.desired_state // empty' 2>/dev/null || echo "")
actual=$(echo "$body" | jq -r '.actual_state // empty' 2>/dev/null || echo "")
if [ -z "$desired" ] || [ -z "$actual" ]; then
  echo "  ✗ Missing desired_state/actual_state in response: $body"
  exit 1
fi
echo "  ✓ desired=$desired actual=$actual"

echo "[TEST] DELETE /api/clusters/$tmp (declarative delete)"
resp=$(http DELETE "/api/clusters/$tmp")
code=$(echo "$resp" | tail -n1)
if [ "$code" != "202" ]; then
  echo "  ✗ Expected 202, got $code"
  exit 1
fi
echo "  ✓ Accepted (reconcile-delete-$tmp)"

echo "[RESULT] Declarative API smoke tests passed"

