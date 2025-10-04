#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

load_secrets() {
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then . "$ROOT_DIR/config/secrets.env"; fi
  : "${PORTAINER_ADMIN_PASSWORD:=admin123}"
  export PORTAINER_ADMIN_PASSWORD
}

ensure_named_volumes() { :; }

ensure_admin_secret() {
  load_secrets
  ensure_named_volumes
  docker volume inspect portainer_secrets >/dev/null 2>&1 || docker volume create portainer_secrets >/dev/null
  # Write PLAINTEXT password as expected by Portainer CE 2.33.x
  docker run --rm -v portainer_secrets:/run/secrets alpine:3.20     sh -lc "umask 077; printf '%s' '"$PORTAINER_ADMIN_PASSWORD"' > /run/secrets/portainer_admin"
}


up() {
  ensure_admin_secret
  docker compose -f "$ROOT_DIR/compose/portainer/docker-compose.yml" up -d
}

down() {
  docker compose -f "$ROOT_DIR/compose/portainer/docker-compose.yml" down -v || true
}

status() {
  docker ps --filter name=portainer-ce
}


api_base() {
  if [ -n "${PORTAINER_API_BASE:-}" ]; then echo "$PORTAINER_API_BASE"; return; fi
  # Prefer HAProxy host if configured, otherwise default to 127.0.0.1:23343
  if [ -z "${HAPROXY_HOST:-}" ] && [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
  if [ -n "${HAPROXY_HOST:-}" ]; then echo "https://${HAPROXY_HOST}:23343"; return; fi
  echo "https://127.0.0.1:23343"
}
api_login() {
  load_secrets
  local pw_json
  if command -v python3 >/dev/null 2>&1; then
    pw_json=$(python3 - <<'PY2'
import json,os
u=json.dumps('admin')
p=json.dumps(os.environ.get('PORTAINER_ADMIN_PASSWORD',''))
print('{"username":%s,"password":%s}'%(u,p))
PY2
)
  else
    pw_json='{"username":"admin","password":"'"$PORTAINER_ADMIN_PASSWORD"'"}'
  fi
  local bases=("$(api_base)" "https://127.0.0.1:9443")
  local jwt="" code body tmp
  for b in "${bases[@]}"; do
    tmp=$(mktemp)
    code=$(curl -sk -o "$tmp" -w '%{http_code}' -X POST "$b/api/auth"       -H 'Content-Type: application/json' -d "$pw_json")
    if [ "$code" = "200" ]; then
      jwt=$(sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p' "$tmp")
      rm -f "$tmp"
      [ -n "$jwt" ] && echo "$jwt" && return 0
    else
      echo "[portainer] auth failed at $b (HTTP $code): $(head -c 120 "$tmp")" >&2
      rm -f "$tmp"
    fi
  done
  return 1
}

endpoint_exists() {
  local name="$1"
  local jwt="$2"
  curl -sk -H "Authorization: Bearer $jwt" "$(api_base)/api/endpoints" | grep -q '"Name":"'"$name"'"'
}

add_endpoint() {
  local name="$1" url="$2"
  local jwt; jwt=$(api_login)
  if [ -z "$jwt" ]; then echo "[portainer] login failed" >&2; return 1; fi
  if endpoint_exists "$name" "$jwt"; then echo "[portainer] endpoint exists: $name"; return 0; fi
  # Use multipart/form-data per Portainer CE 2.33.2 swagger
  # EndpointCreationType=2 (Agent), TLS required, skip verify for self-signed agent
  local tries=10 code
  for i in $(seq 1 $tries); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$(api_base)/api/endpoints" \
      -H "Authorization: Bearer $jwt" \
      -F Name="${name}" \
      -F EndpointCreationType=2 \
      -F URL="${url}" \
      -F TLS=true \
      -F TLSSkipVerify=true \
      -F TLSSkipClientVerify=true \
      -F GroupID=1)
    if [ "$code" = "200" ] || [ "$code" = "201" ] || [ "$code" = "204" ]; then break; fi
    echo "[portainer] add-endpoint HTTP $code (attempt $i/$tries), retrying..." >&2
    sleep 2
  done
  if [ "$code" != "200" ] && [ "$code" != "201" ] && [ "$code" != "204" ]; then
    echo "[portainer] add-endpoint failed (HTTP $code): $name -> $url" >&2
    return 2
  fi
  if endpoint_exists "$name" "$jwt"; then
    echo "[portainer] endpoint added: $name -> $url"
  else
    echo "[portainer] add-endpoint not visible after create: $name" >&2
    return 3
  fi
}

delete_endpoint() {
  local name="$1"
  local jwt; jwt=$(api_login)
  if [ -z "$jwt" ]; then echo "[portainer] login failed" >&2; return 1; fi
  # find id by name (jq optional)
  local eid
  if command -v jq >/dev/null 2>&1; then
    eid=$(curl -sk -H "Authorization: Bearer $jwt" "$(api_base)/api/endpoints" | jq -r '.[] | select(.Name=="'"$name"'") | .Id')
  else
    eid=$(curl -sk -H "Authorization: Bearer $jwt" "$(api_base)/api/endpoints" | sed -n 's/.*{"Id":\([0-9]\+\),"Name":"'"$name"'".*/\1/p')
  fi
  if [ -z "${eid:-}" ]; then echo "[portainer] endpoint not found: $name"; return 0; fi
  curl -sk -X DELETE -H "Authorization: Bearer $jwt" "$(api_base)/api/endpoints/$eid" >/dev/null || true
  echo "[portainer] endpoint deleted: $name (#$eid)"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  api-login) api_login ;;
  add-endpoint) add_endpoint "$2" "$3" ;;
  del-endpoint) delete_endpoint "$2" ;;
  *) echo "Usage: $0 {up|down|status|api-login|add-endpoint <name> <url>|del-endpoint <name>}"; exit 1 ;;
esac
