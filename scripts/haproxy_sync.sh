#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Reconcile HAProxy routes from SQLite (preferred) or CSV with optional pruning.
# Usage: scripts/haproxy_sync.sh [--prune]
# Category: routing
# Status: stable
# See also: scripts/haproxy_route.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# Global lock to serialize full sync/reload cycles (route writes already lock per-call)
LOCK_FILE="${HAPROXY_SYNC_LOCK:-/tmp/haproxy_sync.lock}"
# Allow overriding HAProxy config path for tests via HAPROXY_CFG
CFG="${HAPROXY_CFG:-$ROOT_DIR/compose/infrastructure/haproxy.cfg}"

. "$ROOT_DIR/scripts/lib/lib.sh"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

usage() {
  cat >&2 << USAGE
Usage: $0 [--prune]

说明：
- 优先从 SQLite(clusters) 读取业务集群与 node_port，批量调用 haproxy_route.sh add 进行同步（跳过 devops 与不存在的集群）。
- 当 DB 不可用时回退到 CSV；指定 --prune 时，以"当前源"（DB 或 CSV）为准移除缺失环境路由。
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

is_true() { case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1 | y | yes | true | on) return 0 ;; *) return 1 ;; esac }

acquire_lock() {
  if command -v flock > /dev/null 2>&1; then
    exec 201> "$LOCK_FILE"
    flock -x 201
  else
    # mkdir fallback
    local waited=0
    while ! mkdir "${LOCK_FILE}.dir" 2> /dev/null; do
      sleep 0.1
      waited=$((waited + 1))
      [ $waited -gt 300 ] && break
    done
  fi
}

release_lock() {
  if command -v flock > /dev/null 2>&1; then
    flock -u 201 2> /dev/null || true
    exec 201>&- 2> /dev/null || true
  else
    rm -rf "${LOCK_FILE}.dir" 2> /dev/null || true
  fi
}

validate_cfg() {
  # 允许通过环境变量跳过校验（测试或调试场景）
  if [ "${SKIP_VALIDATE:-0}" = "1" ]; then
    return 0
  fi
  if docker ps --format '{{.Names}}' 2> /dev/null | grep -qx 'haproxy-gw'; then
    local out
    out=$(docker exec haproxy-gw /usr/local/sbin/haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 2>&1 || true)
    # 仅将 ALERT 视为致命错误，忽略 WARNING
    if echo "$out" | grep -q "ALERT"; then
      echo "[sync] ERROR: HAProxy configuration validation failed" >&2
      echo "$out" | grep -E "(ALERT|ERROR)" | head -5 >&2 || true
      return 1
    fi
    return 0
  fi
  echo "[sync] WARN: haproxy-gw not running; skipping validation" >&2
  return 0
}

acquire_lock
trap 'release_lock' EXIT

declare -a records
failed_envs=()
src="db"
if db_is_available > /dev/null 2>&1; then
  # name,provider,node_port
  mapfile -t records < <(sqlite_query "SELECT name, provider, COALESCE(node_port,30080) FROM clusters WHERE name!='devops' ORDER BY name;" 2> /dev/null | sed 's/|/,/g')
else
  src="csv"
  csv="$ROOT_DIR/config/environments.csv"
  [ -f "$csv" ] || {
    echo "[sync] CSV not found: $csv" >&2
    exit 1
  }
  mapfile -t records < <(awk -F, '$0 !~ /^\s*#/ && NF>0 && $1!="devops" {print $1","$2","$3","$6}' "$csv")
fi

if [ ${#records[@]} -eq 0 ]; then
  echo "[sync] no environments found from $src" >&2
  exit 0
fi

echo "[sync] adding/updating routes from $src..."
for entry in "${records[@]}"; do
  IFS=, read -r n provider node_port extra <<< "$entry"
  IFS=$'\n\t'
  [ -n "${n:-}" ] || continue
  # CSV 模式下若提供 haproxy_route 标志，尊重之
  if [ "$src" = "csv" ] && [ -n "${extra:-}" ] && ! is_true "$extra"; then
    continue
  fi
  # 仅对实际存在且可访问的集群生成（kubectl context）
  ctx="$([ "${provider:-k3d}" = "k3d" ] && echo "k3d-${n}" || echo "kind-${n}")"
  if ! kubectl --context "$ctx" get nodes > /dev/null 2>&1; then
    echo "[sync] skip $n ($provider): context not available"
    continue
  fi
  p="${node_port:-30080}"
  if NO_RELOAD=1 "$ROOT_DIR"/scripts/haproxy_route.sh add "$n" --node-port "$p"; then
    :
  else
    echo "[sync] ERROR: failed to add route for $n ($provider)" >&2
    failed_envs+=("$n")
  fi
done

if [ $prune -eq 1 ]; then
  echo "[sync] pruning routes not present in $src..."
  # collect existing env names from haproxy.cfg (host_ ACL markers)
  mapfile -t exist < <(awk '/# BEGIN DYNAMIC ACL/{f=1;next} /# END DYNAMIC ACL/{f=0} f && /acl host_/ {for(i=1;i<=NF;i++){ if($i ~ /^host_/){sub("host_","",$i); print $i}} }' "$CFG" | sort -u)
  # build allow set from current source
  declare -A allow
  allow=()
  for entry in "${records[@]}"; do
    IFS=, read -r n _prov _port _flag <<< "$entry"
    IFS=$'\n\t'
    [ -n "${n:-}" ] || continue
    allow["$n"]=1
  done
  # also collect names referenced in dynamic USE_BACKEND block to catch dangling entries
  mapfile -t ub_exist < <(awk '/# BEGIN DYNAMIC USE_BACKEND/{f=1;next} /# END DYNAMIC USE_BACKEND/{f=0} f && /use_backend[[:space:]]+be_/ { for(i=1;i<=NF;i++){ if($i ~ /^be_/){ sub("be_","",$i); be=$i } if($i ~ /^host_/){ sub("host_","",$i); ho=$i } } if(be==ho && be!="") print be; be=""; ho="" }' "$CFG" | sort -u)
  # and collect names defined in dynamic BACKENDS block (actual backends present)
  mapfile -t bk_exist < <(awk '/# BEGIN DYNAMIC BACKENDS/{f=1;next} /# END DYNAMIC BACKENDS/{f=0} f && /^backend[[:space:]]+be_/ { sub(/^backend[[:space:]]+be_/,"",$0); gsub(/[[:space:]].*$/, "", $0); print $0 }' "$CFG" | sort -u)
  # prune based on ACL presence
  for e in "${exist[@]}"; do
    [ "$e" = "devops" ] && continue
    if [ -z "${allow[$e]:-}" ]; then
      NO_RELOAD=1 "$ROOT_DIR"/scripts/haproxy_route.sh remove "$e" || true
    fi
  done
  # prune dangling use_backend entries even if ACL is already gone
  for e in "${ub_exist[@]}"; do
    [ "$e" = "devops" ] && continue
    # remove if not allowed by current source OR backend not actually defined (dangling)
    if [ -z "${allow[$e]:-}" ]; then
      NO_RELOAD=1 "$ROOT_DIR"/scripts/haproxy_route.sh remove "$e" || true
      continue
    fi
    # check backend existence
    if ! printf '%s\n' "${bk_exist[@]}" | grep -qx -- "$e"; then
      NO_RELOAD=1 "$ROOT_DIR"/scripts/haproxy_route.sh remove "$e" || true
    fi
  done
fi

# 若任一环境的路由添加失败，则直接报告错误并返回非零，交由上层回归脚本捕获
if [ ${#failed_envs[@]} -gt 0 ]; then
  echo "[sync] ERROR: haproxy_route.sh add failed for: ${failed_envs[*]}" >&2
  exit 1
fi

# 单次重载（避免在循环内多次重载）；测试模式或显式 NO_RELOAD=1 时跳过
if [ "${NO_RELOAD:-0}" != "1" ]; then
  if ! validate_cfg; then
    echo "[sync] ERROR: validation failed, aborting haproxy reload" >&2
    exit 1
  fi
  docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" restart haproxy > /dev/null 2>&1 \
    || docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d haproxy > /dev/null
else
  echo "[sync] NO_RELOAD=1 set, skipping haproxy reload"
fi
echo "[sync] done (routes applied from $src)"
