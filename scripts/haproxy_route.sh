#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
DCMD=(docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml")
LOCK_FILE="/tmp/haproxy_route.lock"

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
	# HAProxy 需要连接到集群网络以访问集群
	# 每个 k3d 集群使用独立网络（k3d-<name>），HAProxy 需要连接到这些网络
	
	# 1. k3d 集群：连接到集群的独立网络
	if [ "$provider" = "k3d" ]; then
		local dedicated_network="k3d-${name}"
		if docker network inspect "$dedicated_network" >/dev/null 2>&1; then
			echo "[haproxy] Connecting to k3d network: $dedicated_network"
			docker network connect "$dedicated_network" haproxy-gw 2>/dev/null || true
		else
			echo "[haproxy] WARN: Network $dedicated_network not found"
		fi
		return 0
	fi
	
	# 2. kind 集群：连接到 kind 网络（如果存在）
	if [ "$provider" = "kind" ]; then
		if docker network inspect "kind" >/dev/null 2>&1; then
			echo "[haproxy] Connecting to kind network"
			docker network connect "kind" haproxy-gw 2>/dev/null || true
		fi
		return 0
	fi
	
	# 3. 其他情况：尝试使用 network_name 变量（兼容性）
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

# 获取文件锁（使用flock或mkdir作为fallback）
acquire_lock() {
	if command -v flock >/dev/null 2>&1; then
		# 使用 flock (推荐)
		exec 200>"$LOCK_FILE"
		flock -x 200
	else
		# fallback: 使用 mkdir 原子性
		local max_wait=30 waited=0
		while ! mkdir "$LOCK_FILE.dir" 2>/dev/null; do
			sleep 0.1
			waited=$((waited+1))
			if [ $waited -gt $((max_wait*10)) ]; then
				echo "[WARN] Lock timeout, forcing acquisition" >&2
				rm -rf "$LOCK_FILE.dir" 2>/dev/null || true
				mkdir "$LOCK_FILE.dir" 2>/dev/null || true
				break
			fi
		done
	fi
}

# 释放文件锁
release_lock() {
	if command -v flock >/dev/null 2>&1; then
		flock -u 200 2>/dev/null || true
		exec 200>&- 2>/dev/null || true
	else
		rm -rf "$LOCK_FILE.dir" 2>/dev/null || true
	fi
}

add_acl() {
	local tmp acl_begin acl_end cluster_type env_name
	acl_begin="^[[:space:]]*# BEGIN DYNAMIC ACL"
	acl_end="^[[:space:]]*# END DYNAMIC ACL"
	
	# Determine cluster type and environment name for naming convention
	case "$provider" in
		k3d) 
			cluster_type="k3d"
			# 使用完整的环境名（包括 -k3d 后缀）
			env_name="$name"
			;;
		kind) 
			cluster_type="kind"
			env_name="$name"
			;;
		*) 
			cluster_type="unknown"
			env_name="$label"
			;;
	esac
	
	tmp=$(mktemp)
	awk -v n="$name" -v en="$env_name" -v ct="$cluster_type" -v B="$acl_begin" -v E="$acl_end" '
    BEGIN{ins=0}
    {print $0}
    $0 ~ B {
      if (ct == "unknown") {
        # Fallback to old naming convention
        print "  acl host_" n "  hdr_reg(host) -i ^[^.]+\\." en "\\.[^:]+"
      } else {
        # New naming convention: {service}.{cluster_type}.{env}.{base_domain}
        print "  acl host_" n "  hdr_reg(host) -i ^[^.]+\\." ct "\\." en "\\.[^:]+"
      }
      print "  use_backend be_" n " if host_" n
      ins=1
    }
  ' "$CFG" >"$tmp"
	mv "$tmp" "$CFG" && chmod 644 "$CFG" || true
}


add_backend() {
	local tmp b_begin b_end ip detected_port
	# Resolve cluster node container IP and always target NodePort for simplicity (k3d and kind)
	if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}-control-plane" 2>/dev/null) && [ -n "$ip" ]; then
		# kind cluster detected - use NodePort on control-plane container IP
		detected_port="$node_port"
	elif [ "$provider" = "k3d" ]; then
		# k3d cluster: 优先从独立网络获取 IP，回退到共享网络
		local dedicated_network="k3d-${name}"
		if docker network inspect "$dedicated_network" >/dev/null 2>&1; then
			# 从独立网络获取 IP
			ip=$(docker inspect "k3d-${name}-server-0" --format "{{with index .NetworkSettings.Networks \"$dedicated_network\"}}{{.IPAddress}}{{end}}" 2>/dev/null || true)
		fi
		if [ -z "$ip" ]; then
			# 回退：从共享网络获取 IP
			ip=$(docker inspect "k3d-${name}-server-0" --format '{{with index .NetworkSettings.Networks "k3d-shared"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)
		fi
		if [ -z "$ip" ]; then
			# 最后回退：获取任意网络的 IP
			ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "k3d-${name}-server-0" 2>/dev/null | head -1 || true)
		fi
		detected_port="$node_port"
	else
		ip="127.0.0.1" # fallback (may not work for kind)
		detected_port="$node_port"
	fi
	
	if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
		echo "[WARN] Could not resolve container IP for cluster $name, using fallback 127.0.0.1" >&2
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
	if [ -n "${NO_RELOAD:-}" ] && [ "${NO_RELOAD}" = "1" ]; then
		return 0
	fi
	if ! "${DCMD[@]}" restart >/dev/null 2>&1; then
		"${DCMD[@]}" up -d >/dev/null
	fi
}

case "$cmd" in
add)
	# Determine environment name for output
	output_env_name=""
	case "$provider" in
		k3d) output_env_name="${name%-k3d}" ;;
		kind) output_env_name="$name" ;;
		*) output_env_name="$label" ;;
	esac
	
	if [ "${DRY_RUN:-}" = "1" ]; then
		if [ "$provider" = "k3d" ] || [ "$provider" = "kind" ]; then
			echo "[DRY-RUN][haproxy] add route for $name (host: <svc>.${provider}.${output_env_name}.${BASE_DOMAIN}, node-port=$node_port)"
		else
			echo "[DRY-RUN][haproxy] add route for $name (host: <svc>.${output_env_name}.${BASE_DOMAIN}, node-port=$node_port)"
		fi
	else
		# 获取锁保护配置文件修改
		acquire_lock
		remove_acl || true
		remove_backend || true
		add_acl
		add_backend
		ensure_network
		reload
		release_lock
		if [ "$provider" = "k3d" ] || [ "$provider" = "kind" ]; then
			echo "[haproxy] added route for $name (pattern: <service>.${provider}.${output_env_name}.${BASE_DOMAIN}, node-port=$node_port)"
		else
			echo "[haproxy] added route for $name (pattern: <service>.${output_env_name}.${BASE_DOMAIN}, node-port=$node_port)"
		fi
	fi
	;;
remove)
	if [ "${DRY_RUN:-}" = "1" ]; then
		echo "[DRY-RUN][haproxy] remove route for $name"
	else
		# 获取锁保护配置文件修改
		acquire_lock
		remove_acl
		remove_backend
		reload
		release_lock
		echo "[haproxy] removed route for $name"
	fi
	;;
*) usage ;;
esac
