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
	# k3d 集群：有独立子网的使用 k3d-<name> 网络，无子网的使用共享网络 k3d-shared
	
	# 1. k3d 集群：检查是否有独立子网
	if [ "$provider" = "k3d" ]; then
		# 从 CSV 读取子网配置
		local subnet
		subnet="$(subnet_for "$name" 2>/dev/null || true)"
		
		if [ -n "$subnet" ]; then
			# 有独立子网：连接到专用网络（检查幂等性）
			local dedicated_network="k3d-${name}"
			if docker network inspect "$dedicated_network" >/dev/null 2>&1; then
				if docker inspect haproxy-gw 2>/dev/null | jq -e ".[0].NetworkSettings.Networks.\"$dedicated_network\"" >/dev/null 2>&1; then
					echo "[haproxy] Already connected to k3d network: $dedicated_network"
				else
					echo "[haproxy] Connecting to k3d network: $dedicated_network"
					docker network connect "$dedicated_network" haproxy-gw
				fi
			else
				echo "[haproxy] WARN: Network $dedicated_network not found"
			fi
		else
			# 无子网（使用共享网络）：HAProxy 已在 bootstrap 时连接到 k3d-shared
			echo "[haproxy] Cluster $name uses shared network k3d-shared (already connected)"
		fi
		return 0
	fi
	
	# 2. kind 集群：连接到 kind 网络（如果存在且未连接）
	if [ "$provider" = "kind" ]; then
		if docker network inspect "kind" >/dev/null 2>&1; then
			# 检查 HAProxy 是否已连接到 kind 网络（幂等性）
			if docker inspect haproxy-gw 2>/dev/null | jq -e '.[0].NetworkSettings.Networks.kind' >/dev/null 2>&1; then
				echo "[haproxy] Already connected to kind network"
			else
				echo "[haproxy] Connecting to kind network"
				docker network connect "kind" haproxy-gw
			fi
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
	local tmp acl_begin acl_end env_name
	acl_begin="^[[:space:]]*# BEGIN DYNAMIC ACL"
	acl_end="^[[:space:]]*# END DYNAMIC ACL"
	
	# 使用完整集群名作为域名环境部分（避免 ACL 冲突）
	# 新的域名格式：service.cluster_name.base_domain
	# 例如：dev -> whoami.dev.xxx, dev-k3d -> whoami.dev-k3d.xxx
	env_name="$name"
	
	tmp=$(mktemp)
	# 新的 ACL 模式：匹配 service.env.base_domain
	# 例如：whoami.dev.192.168.51.30.sslip.io
	awk -v n="$name" -v en="$env_name" -v B="$acl_begin" -v E="$acl_end" '
    BEGIN{ins=0}
    {print $0}
    $0 ~ B {
      # ACL 模式：匹配 <service>.<env>.<base-domain>
      print "  acl host_" n "  hdr_reg(host) -i ^[^.]+\\." en "\\.[^:]+"
      print "  use_backend be_" n " if host_" n
      ins=1
    }
  ' "$CFG" >"$tmp"
	mv "$tmp" "$CFG" && chmod 644 "$CFG" || true
}


add_backend() {
	local tmp b_begin b_end ip detected_port
	
	# 从 CSV 或数据库获取 http_port（实际暴露在宿主机的端口）
	local http_port
	http_port=$(awk -F, -v n="$name" 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print $7; exit}' "$ROOT_DIR/config/environments.csv" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")
	
	# Resolve cluster node container IP and target port
	if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}-control-plane" 2>/dev/null | head -1) && [ -n "$ip" ]; then
		# kind cluster detected - 使用容器 IP:node_port（通过 Docker 网络直接访问）
		detected_port="$node_port"
		echo "[haproxy] kind cluster $name: using container IP $ip:$detected_port"
	elif [ "$provider" = "k3d" ]; then
		# k3d cluster: HAProxy直接访问server-0的NodePort（Traefik Ingress Controller）
		# 不使用serverlb，因为Traefik移除了hostPort配置（避免多集群冲突）
		server_name="k3d-${name}-server-0"
		if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$server_name" 2>/dev/null | head -1) && [ -n "$ip" ]; then
			detected_port="$node_port"  # 直接访问Traefik的NodePort
			echo "[haproxy] k3d cluster $name: using server-0 IP $ip:$detected_port (NodePort)"
		else
			echo "[ERROR] k3d cluster $name: cannot find server container $server_name" >&2
			return 1
		fi
	else
		ip="127.0.0.1" # fallback
		detected_port="${http_port:-$node_port}"
	fi
	
	if [ -z "$ip" ]; then
		echo "[WARN] Could not resolve IP for cluster $name, using fallback 127.0.0.1" >&2
		ip="127.0.0.1"
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

validate_config() {
	# Validate HAProxy configuration using the running container
	# This avoids permission issues with volume mounts
	local validation_output
	validation_output=$(docker exec haproxy-gw /usr/local/sbin/haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 2>&1)
	
	# Check for fatal errors (ALERT), ignore warnings
	if echo "$validation_output" | grep -q "ALERT"; then
		echo "[ERROR] HAProxy configuration validation failed" >&2
		echo "$validation_output" | grep -E "(ALERT|ERROR)" | head -5 >&2 || true
		return 1
	fi
	return 0
}

route_exists() {
	# Check if route already exists (both ACL and backend)
	local n="$1"
	grep -q "acl host_${n}" "$CFG" && grep -q "backend be_${n}" "$CFG"
}

reload() {
	if [ -n "${NO_RELOAD:-}" ] && [ "${NO_RELOAD}" = "1" ]; then
		return 0
	fi
	
	# Validate configuration before reloading
	if ! validate_config; then
		echo "[ERROR] HAProxy configuration invalid, skipping reload" >&2
		return 1
	fi
	
	if ! "${DCMD[@]}" restart >/dev/null 2>&1; then
		"${DCMD[@]}" up -d >/dev/null
	fi
	
	# Verify HAProxy is running after reload
	sleep 2
	if ! docker ps --filter name=haproxy-gw --filter status=running | grep -q haproxy-gw; then
		echo "[ERROR] HAProxy failed to start after reload" >&2
		docker logs haproxy-gw --tail 20 2>&1 || true
		return 1
	fi
	return 0
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
		# Check if route already exists (idempotent)
		if route_exists "$name"; then
			echo "[haproxy] route for $name already exists, updating..."
		fi
		
		# 获取锁保护配置文件修改
		acquire_lock
		
		# Backup current config
		# 确保配置文件可写
		if [ ! -w "$CFG" ]; then
			echo "[haproxy] Fixing config file permissions..."
			chmod 644 "$CFG" || {
				echo "[ERROR] Cannot write to $CFG" >&2
				release_lock
				exit 1
			}
		fi
		
		cp "$CFG" "${CFG}.backup" 2>/dev/null || true
		
		# Remove existing entries (idempotent)
		remove_acl || true
		remove_backend || true
		
		# Add new entries
		add_acl
		add_backend
		
		# Validate before reload
		if ! validate_config; then
			echo "[ERROR] Configuration validation failed, restoring backup" >&2
			mv "${CFG}.backup" "$CFG" 2>/dev/null || true
			release_lock
			exit 1
		fi
		
		# Connect HAProxy to cluster network
		ensure_network
		
		# Reload HAProxy
		if ! reload; then
			echo "[ERROR] HAProxy reload failed, restoring backup" >&2
			mv "${CFG}.backup" "$CFG" 2>/dev/null || true
			reload || true
			release_lock
			exit 1
		fi
		
		# Cleanup backup on success
		rm -f "${CFG}.backup" 2>/dev/null || true
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
