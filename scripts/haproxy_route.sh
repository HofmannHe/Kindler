#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
DCMD=(docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml")

# load base domain suffix from config if present
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=local}"

usage() { echo "Usage: $0 {add|remove} <env-name> [--node-port <port>]" >&2; exit 1; }

cmd="${1:-}"; name="${2:-}"; shift 2 || true
# options
node_port=30080
while [ $# -gt 0 ]; do
  case "$1" in
    --node-port)
      node_port="$2"; shift 2 ;;
    --node-port=*)
      node_port="${1#--node-port=}"; shift ;;
    *) break ;;
  esac
done
[ -n "$cmd" ] && [ -n "$name" ] || usage

add_acl() {
  local tmp acl_begin acl_end
  acl_begin="^[[:space:]]*# BEGIN DYNAMIC ACL"
  acl_end="^[[:space:]]*# END DYNAMIC ACL"
  tmp=$(mktemp)
  awk -v n="$name" -v d="$BASE_DOMAIN" -v B="$acl_begin" -v E="$acl_end" '
    BEGIN{ins=0}
    {print $0}
    $0 ~ B {print "  acl host_" n "  hdr_reg(host) -i ^" n "\\.[^:]+"; print "  use_backend be_" n " if host_" n; ins=1}
  ' "$CFG" >"$tmp"
  mv "$tmp" "$CFG" && chmod 644 "$CFG" || true
}

add_backend() {
  local tmp b_begin b_end ip detected_port
  # try to resolve cluster node (kind/k3d) container IP to target NodePort
  if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}-control-plane" 2>/dev/null); then
    # kind cluster detected - use NodePort
    detected_port="$node_port"
  elif ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "k3d-${name}-server-0" 2>/dev/null); then
    # k3d cluster detected - use LoadBalancer port 80
    detected_port=80
  else
    ip="127.0.0.1" # fallback (may not work for kind)
    detected_port="$node_port"
  fi
  b_begin="^# BEGIN DYNAMIC BACKENDS"
  b_end="^# END DYNAMIC BACKENDS"
  tmp=$(mktemp)
  awk -v n="$name" -v B="$b_begin" -v E="$b_end" -v p="$detected_port" '
    {print $0}
    $0 ~ B {print "backend be_" n "\n  server s1 REPLACE_IP:" p}
  ' "$CFG" >"$tmp"
  mv "$tmp" "$CFG" && chmod 644 "$CFG" || true
  # replace placeholder with resolved IP
  sed -i -e "s/REPLACE_IP/${ip}/" "$CFG"
}

remove_acl() {
  local tmp
  tmp=$(mktemp)
  awk -v n="$name" '
    BEGIN{skip=0}
    {
      if ($0 ~ "^[[:space:]]*acl[[:space:]]+host_" n "[[:space:]]+") next;
      if ($0 ~ "^[[:space:]]*use_backend[[:space:]]+be_" n "[[:space:]]+") next;
      print $0
    }
  ' "$CFG" >"$tmp"
  mv "$tmp" "$CFG" && chmod 644 "$CFG" || true
}


remove_backend() {
  local tmp
  tmp=$(mktemp)
  awk -v n="$name" 'BEGIN{inblk=0}
    /^backend be_/ {inblk=($2=="be_" n)}
    inblk {next}
    {print $0}
  ' "$CFG" >"$tmp"
  mv "$tmp" "$CFG" && chmod 644 "$CFG" || true
}

reload() {
  if ! "${DCMD[@]}" restart >/dev/null 2>&1; then
    "${DCMD[@]}" up -d >/dev/null
  fi
}

case "$cmd" in
  add)
    remove_acl || true; remove_backend || true
    add_acl; add_backend; reload; echo "[haproxy] added route for $name (domain: $name.$BASE_DOMAIN, node-port=$node_port)" ;;
  remove)
    remove_acl; remove_backend; reload; echo "[haproxy] removed route for $name" ;;
  *) usage ;;
 esac
