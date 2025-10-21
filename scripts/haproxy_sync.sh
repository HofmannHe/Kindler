#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"

usage() {
	cat >&2 <<USAGE
Usage: $0 [--prune]

说明：
- 从 config/environments.csv 读取环境列表与 node_port，批量调用 haproxy_route.sh add 进行同步。
- 指定 --prune 时，会移除 haproxy.cfg 中存在但 CSV 中缺失的环境路由。
USAGE
}

prune=0
while [ $# -gt 0 ]; do
	case "$1" in
	--prune)
		prune=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown option: $1" >&2
		usage
		exit 2
		;;
	esac
done

csv="$ROOT_DIR/config/environments.csv"
[ -f "$csv" ] || {
	echo "[sync] CSV not found: $csv" >&2
	exit 1
}

# read env and node_port from CSV
mapfile -t records < <(awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1","$3","$6}' "$csv")

is_true() {
	case "$(echo "${1:-}" | tr 'A-Z' 'a-z')" in
	1 | y | yes | true | on) return 0 ;;
	*) return 1 ;;
	esac
}

if [ ${#records[@]} -eq 0 ]; then
	echo "[sync] no environments found in CSV" >&2
	exit 0
fi

# 首先更新PostgreSQL backend IP（必须在任何HAProxy验证之前）
echo "[sync] updating PostgreSQL backend IP..."
# 获取devops集群在k3d-shared网络中的IP（PostgreSQL所在网络）
DEVOPS_NODE_IP=$(docker inspect k3d-devops-server-0 --format '{{index .NetworkSettings.Networks "k3d-shared" "IPAddress"}}' 2>/dev/null || echo "")

# 如果k3d-shared网络IP为空，使用第一个可用网络的IP
if [ -z "$DEVOPS_NODE_IP" ] || [ "$DEVOPS_NODE_IP" = "<no value>" ]; then
  DEVOPS_NODE_IP=$(docker inspect k3d-devops-server-0 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
fi

if [ -n "$DEVOPS_NODE_IP" ] && [ "$DEVOPS_NODE_IP" != "null" ]; then
  echo "[sync] devops node IP: $DEVOPS_NODE_IP"
  # 使用临时文件替换占位符（连接到NodePort 30432）
  sed "s/__DEVOPS_POSTGRES_IP__/$DEVOPS_NODE_IP/g" "$CFG" > "$CFG.tmp"
  mv "$CFG.tmp" "$CFG"
  echo "[sync] PostgreSQL backend updated to $DEVOPS_NODE_IP:30432 (NodePort)"
else
  echo "[sync] warning: devops集群未运行，使用占位符127.0.0.1"
  sed "s/__DEVOPS_POSTGRES_IP__/127.0.0.1/g" "$CFG" > "$CFG.tmp"
  mv "$CFG.tmp" "$CFG"
fi

echo "[sync] adding/updating routes from CSV..."
NO_RELOAD=1 export NO_RELOAD
for entry in "${records[@]}"; do
	IFS=, read -r n p flag <<<"$entry"
	IFS=$'\n\t'
	[ -n "$n" ] || continue
	if [ -n "${flag:-}" ] && ! is_true "$flag"; then
		continue
	fi
    p="${p:-30080}"
    NO_RELOAD=1 "$ROOT_DIR"/scripts/haproxy_route.sh add "$n" --node-port "$p" || true
done

if [ $prune -eq 1 ]; then
	echo "[sync] pruning routes not present in CSV..."
	# collect existing env names from haproxy.cfg (host_ and backend be_)
	mapfile -t exist < <(awk '/# BEGIN DYNAMIC ACL/{f=1;next} /# END DYNAMIC ACL/{f=0} f && /acl host_/ {for(i=1;i<=NF;i++){ if($i ~ /^host_/){sub("host_","",$i); print $i}} }' "$CFG" | sort -u)
	for e in "${exist[@]}"; do
		keep=0
		for entry in "${records[@]}"; do
			IFS=, read -r n _p flag <<<"$entry"
			IFS=$'\n\t'
			[ "$e" = "$n" ] || continue
			if [ -n "${flag:-}" ] && ! is_true "$flag"; then
				keep=0
			else
				keep=1
			fi
			break
		done
		if [ $keep -eq 0 ]; then
			NO_RELOAD=1 "$ROOT_DIR"/scripts/haproxy_route.sh remove "$e" || true
		fi
	done
fi

docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" restart haproxy >/dev/null 2>&1 || docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d haproxy >/dev/null
echo "[sync] done (reloaded once)"
