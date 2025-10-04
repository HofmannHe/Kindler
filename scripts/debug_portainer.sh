#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
report="$ROOT_DIR/docs/TEST_REPORT.md"

base_from_cfg() {
  local H="${HAPROXY_HOST:-}"
  if [ -z "$H" ] && [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
  : "${HAPROXY_HOST:=127.0.0.1}"
  echo "https://${HAPROXY_HOST}:23343"
}

run_one() {
  local base="$1"
  echo "## Portainer Debug ($base)" >> "$report"
  # login
  local jwt code tmp pw
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then . "$ROOT_DIR/config/secrets.env"; fi
  pw="${PORTAINER_ADMIN_PASSWORD:-admin123}"
  tmp=$(mktemp)
  code=$(curl -sk -o "$tmp" -w '%{http_code}' -X POST "$base/api/auth" \
    -H 'Content-Type: application/json' -d '{"username":"admin","password":"'"$pw"'"}') || true
  echo "- auth HTTP: $code" >> "$report"
  if [ "$code" = "200" ]; then
    jwt=$(sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p' "$tmp")
    echo "- jwt_len: ${#jwt}" >> "$report"
  else
    echo "- auth body: $(head -c 160 "$tmp")" >> "$report"
  fi
  rm -f "$tmp"
  # endpoints
  tmp=$(mktemp)
  code=$(curl -sk -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $jwt" "$base/api/endpoints") || true
  echo "- endpoints HTTP: $code" >> "$report"
  if [ "$code" = "200" ]; then
    { command -v jq >/dev/null 2>&1 && jq -r '.[].Name' "$tmp" || cat "$tmp"; } | sed 's/^/  /' >> "$report"
  else
    echo "- endpoints body: $(head -c 160 "$tmp")" >> "$report"
  fi
  rm -f "$tmp"
  echo >> "$report"
}

main() {
  mkdir -p "$ROOT_DIR/docs"
  echo "# Portainer Debug @ $(date '+%F %T')" >> "$report"
  echo "- base(cfg): $(base_from_cfg)" >> "$report"
  echo >> "$report"
  run_one "$(base_from_cfg)"
  run_one "https://127.0.0.1:23343"
  echo "---" >> "$report"
  echo "[debug] report appended to $report"
}

main "$@"
