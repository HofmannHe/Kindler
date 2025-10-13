#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
CSV="$ROOT_DIR/config/environments.csv"

. "$ROOT_DIR/scripts/lib.sh"
load_env

usage() {
  cat >&2 <<USG
Usage: $0 [--dry-run]

说明：
- 仅渲染动态后端（BACKENDS），不改动 ACL 区域；根据 CSV (haproxy_route=true) 生成后端列表。
- 单次重载 HAProxy。
USG
}

dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

resolve_ip() {
  local env="$1" ip=""
  if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${env}-control-plane" 2>/dev/null); then
    echo "$ip"; return 0
  fi
  if ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "k3d-shared"}}{{.IPAddress}}{{end}}' "k3d-${env}-server-0" 2>/dev/null); then
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "k3d-${env}-server-0" 2>/dev/null); then
    echo "$ip"; return 0
  fi
  echo 127.0.0.1
}

is_true() {
  case "$(echo "${1:-}" | tr 'A-Z' 'a-z')" in 1|y|yes|true|on) return 0;; *) return 1;; esac
}

render_backends() {
  [ -f "$CSV" ] || { echo "[render] CSV not found: $CSV" >&2; exit 1; }
  [ -f "$CFG" ] || { echo "[render] CFG not found: $CFG" >&2; exit 1; }
  tmp_be=$(mktemp)
  while IFS=, read -r env provider node_port pf_port reg_portainer haproxy_route http_port https_port; do
    [[ "$env" =~ ^[[:space:]]*# ]] && continue
    [ -n "$env" ] || continue
    if [ -n "${haproxy_route:-}" ] && ! is_true "$haproxy_route"; then
      continue
    fi
    ip=$(resolve_ip "$env"); port="${node_port:-30080}"
    printf 'backend be_%s\n  server s1 %s:%s\n' "$env" "$ip" "$port" >> "$tmp_be"
  done < <(grep -v '^\s*$' "$CSV")

  tmp="$CFG.tmp"
  awk -v befile="$tmp_be" '
    BEGIN{inbe=0}
    {
      if ($0 ~ /# BEGIN DYNAMIC BACKENDS/) {print; system("cat " befile); inbe=1; next}
      if (inbe && $0 ~ /^backend be_portainer_https/) {inbe=0}
      if (!inbe) print
    }
  ' "$CFG" > "$tmp"
  mv "$tmp" "$CFG"
  rm -f "$tmp_be"
}

main() {
  render_backends
  if [ "$dry" = 1 ]; then
    echo "[haproxy] dry-run backend render complete (no restart)."
  else
    docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" restart haproxy >/dev/null 2>&1 || \
      docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d haproxy >/dev/null
    echo "[haproxy] backends rendered and reloaded."
  fi
}

main "$@"
