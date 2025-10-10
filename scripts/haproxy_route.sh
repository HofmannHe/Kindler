#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
DCMD=(docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml")

# load base domain suffix from config if present
if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
: "${BASE_DOMAIN:=local}"
load_env

usage() {
	echo "Usage: $0 {add|remove} <env-name> [--node-port <port>]" >&2
	exit 1
}

cmd="${1:-}"
name="${2:-}"
shift 2 || true
label="$(env_label "$name")"
[ -n "$label" ] || label="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
provider="$(provider_for "$name")"
case "$provider" in
k3d) network_name="k3d-${name}" ;;
kind) network_name="kind" ;;
*) network_name="" ;;
esac

ensure_network() {
	# HAProxy 需要连接到 k3d-shared 网络以访问所有集群
	local shared_network="k3d-shared"
	if docker network inspect "$shared_network" >/dev/null 2>&1; then
		docker network connect "$shared_network" haproxy-gw 2>/dev/null || true
	fi
	# 兼容旧的独立网络模式
	if [ -n "${network_name:-}" ]; then
		docker network connect "$network_name" haproxy-gw 2>/dev/null || true
	fi
}
# options
node_port=30080
while [ $# -gt 0 ]; do
	case "$1" in
	--node-port)
		node_port="$2"
		shift 2
		;;
	--node-port=*)
		node_port="${1#--node-port=}"
		shift
		;;
	*) break ;;
	esac
done
[ -n "$cmd" ] && [ -n "$name" ] || usage

add_acl() {
	local tmp acl_begin acl_end
	acl_begin="^[[:space:]]*# BEGIN DYNAMIC ACL"
	acl_end="^[[:space:]]*# END DYNAMIC ACL"
	tmp=$(mktemp)
	awk -v n="$name" -v l="$label" -v B="$acl_begin" -v E="$acl_end" '
    BEGIN{ins=0}
    {print $0}
    $0 ~ B {print "  acl host_" n "  hdr_reg(host) -i ^[^.]+\\." l "\\.[^:]+"; print "  use_backend be_" n " if host_" n; ins=1}
  ' "$CFG" >"$tmp"
	mv "$tmp" "$CFG" && chmod 644 "$CFG" || true
}


add_backend() {
	local tmp b_begin b_end ip detected_port
	# Resolve cluster node container IP and always target NodePort for simplicity (k3d and kind)
	if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}-control-plane" 2>/dev/null); then
		# kind cluster detected - use NodePort on control-plane container IP
		detected_port="$node_port"
	elif ip=$(docker inspect "k3d-${name}-server-0" --format '{{with index .NetworkSettings.Networks "k3d-shared"}}{{.IPAddress}}{{end}}' 2>/dev/null) && [ -n "$ip" ]; then
		# k3d cluster on shared network - use server-0 container IP + NodePort
		detected_port="$node_port"
	elif ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "k3d-${name}-server-0" 2>/dev/null); then
		# k3d cluster (legacy/without shared network info) - use server-0 container IP + NodePort
		detected_port="$node_port"
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
	if [ "${DRY_RUN:-}" = "1" ]; then
		echo "[DRY-RUN][haproxy] add route for $name (host: <svc>.${label}.${BASE_DOMAIN}, node-port=$node_port)"
	else
		remove_acl || true
		remove_backend || true
		add_acl
		add_backend
		ensure_network
		reload
		echo "[haproxy] added route for $name (pattern: <service>.${label}.${BASE_DOMAIN}, node-port=$node_port)"
	fi
	;;
remove)
	if [ "${DRY_RUN:-}" = "1" ]; then
		echo "[DRY-RUN][haproxy] remove route for $name"
	else
		remove_acl
		remove_backend
		reload
		echo "[haproxy] removed route for $name"
	fi
	;;
*) usage ;;
esac
