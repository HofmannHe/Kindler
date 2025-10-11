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
- 读取 environments.csv 渲染 haproxy 动态 ACL 与动态后端，一次写入并单次重启。
- 始终以 CSV 的 haproxy_route=true 作为启用依据（隐式完成 prune）。
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

ensure_gateway_networks() {
  docker network connect k3d-shared haproxy-gw 2>/dev/null || true
  docker network connect kind haproxy-gw 2>/dev/null || true
}

env_to_label() { env_label "$1"; }

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

render_blocks() {
  [ -f "$CSV" ] || { echo "[render] CSV not found: $CSV" >&2; exit 1; }
  [ -f "$CFG" ] || { echo "[render] CFG not found: $CFG" >&2; exit 1; }
  local BASE_DOMAIN_LOCAL="$BASE_DOMAIN"
  if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
  : "${BASE_DOMAIN_LOCAL:=${BASE_DOMAIN:-local}}"

  # build lists
  local ACL="" BE=""
  while IFS=, read -r env provider node_port pf_port reg_portainer haproxy_route http_port https_port; do
    [[ "$env" =~ ^[[:space:]]*# ]] && continue
    [ -n "$env" ] || continue
    if [ -n "${haproxy_route:-}" ] && ! is_true "$haproxy_route"; then
      continue
    fi
    local label="$(env_to_label "$env")"
    local ip port
    ip="$(resolve_ip "$env")"; port="${node_port:-30080}"
    ACL+=$(printf '  acl host_%s  hdr_reg(host) -i ^[^.]+\\.%s\\.[^:]+'"\n"'  use_backend be_%s if host_%s'"\n" "$env" "$label" "$env" "$env")
    BE+=$(printf 'backend be_%s'"\n"'  server s1 %s:%s'"\n" "$env" "$ip" "$port")
  done < <(grep -v '^\s*$' "$CSV")

  # write back to cfg: replace between markers for ACL; replace backends block between BEGIN and the first 'backend be_portainer_https'
  local tmp="$CFG.tmp"
  awk -v acl="$ACL" '
    BEGIN{inacl=0}
    {
      if ($0 ~ /# BEGIN DYNAMIC ACL/) {print; print acl; inacl=1; next}
      if (inacl && $0 ~ /# END DYNAMIC ACL/) {print; inacl=0; next}
      if (!inacl) print
    }
  ' "$CFG" > "$tmp.1"

  awk -v be="$BE" '
    BEGIN{inbe=0}
    {
      if ($0 ~ /# BEGIN DYNAMIC BACKENDS/) {print; print be; inbe=1; next}
      if (inbe && $0 ~ /^backend be_portainer_https/) {inbe=0}
      if (!inbe) print
    }
  ' "$tmp.1" > "$tmp.2"

  mv "$tmp.2" "$CFG"
  rm -f "$tmp.1"
}

main() {
  ensure_gateway_networks
  render_blocks
  if [ "$dry" = 1 ]; then
    echo "[haproxy] dry-run render complete (no restart)."
  else
    docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" restart haproxy >/dev/null 2>&1 || \
      docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d haproxy >/dev/null
    echo "[haproxy] rendered and reloaded."
  fi
}

main "$@"
