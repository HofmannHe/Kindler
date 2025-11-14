#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Remove Portainer endpoints (and optional DB rows) for clusters that no longer exist.
# Usage: scripts/cleanup_nonexistent_clusters.sh [--dry-run] [--prune-db]
# Category: lifecycle
# Status: experimental
# See also: scripts/reconcile.sh, scripts/db_verify.sh, scripts/portainer.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

usage() {
  cat << 'USAGE'
Usage: scripts/cleanup_nonexistent_clusters.sh [--dry-run] [--prune-db]

Options:
  --dry-run    仅打印计划，不执行删除动作。
  --prune-db   调用 scripts/reconcile.sh --prune-missing，删除 SQLite 中缺失的记录。
  -h, --help   显示帮助。

说明：
- 默认只比对 SQLite / 实际集群与 Portainer，清理 Portainer 中的残留端点。
- 使用 --prune-db 可额外移除 SQLite 中的孤儿记录（调用现有调和脚本，保持幂等）。
USAGE
}

DRY_RUN=false
PRUNE_DB=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --prune-db)
      PRUNE_DB=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[cleanup] 未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

log_info() { printf '[cleanup] %s\n' "$*"; }
log_warn() { printf '[cleanup] WARN: %s\n' "$*" >&2; }
log_error() { printf '[cleanup] ERROR: %s\n' "$*" >&2; }

add_no_proxy_host() {
  local host="$1"
  [ -n "$host" ] || return 0
  local current="${NO_PROXY:-${no_proxy:-}}"
  if [ -n "$current" ]; then
    case ",${current}," in
      *",${host},"*) return 0 ;;
      *) current="${current},${host}" ;;
    esac
  else
    current="$host"
  fi
  export NO_PROXY="$current"
  export no_proxy="$current"
}

host_from_url() {
  local url="$1"
  url="${url#*://}"
  url="${url%%/*}"
  printf '%s' "${url%%:*}"
}

declare -A DESIRED_MAP=()
declare -A KEEP_MAP=()

mark_desired() {
  local name="$1"
  [ -z "$name" ] && return
  DESIRED_MAP["$name"]=1
  KEEP_MAP["$name"]=1
}

mark_running() {
  local name="$1"
  [ -z "$name" ] && return
  KEEP_MAP["$name"]=1
}

collect_desired_clusters() {
  if ! sqlite_is_available > /dev/null 2>&1; then
    log_warn "SQLite 不可用，跳过数据库基准"
    return 1
  fi

  local rows
  rows=$(sqlite_query "SELECT name, COALESCE(desired_state, 'present') FROM clusters;" 2> /dev/null || true)
  if [ -z "$rows" ]; then
    log_warn "SQLite 中没有业务集群记录"
    return 0
  fi

  while IFS='|' read -r name desired; do
    [ -n "$name" ] || continue
    [ "$desired" = "present" ] || continue
    mark_desired "$name"
  done < <(printf '%s\n' "$rows")
}

list_k3d_clusters() {
  command -v k3d > /dev/null 2>&1 || return 0
  if command -v jq > /dev/null 2>&1; then
    k3d cluster list -o json 2> /dev/null | jq -r '.[].name' 2> /dev/null || true
  else
    k3d cluster list 2> /dev/null | awk 'NR>1 && $1 !~ /NAME/ {gsub(/\r/, "", $1); print $1}' || true
  fi
}

list_kind_clusters() {
  command -v kind > /dev/null 2>&1 || return 0
  kind get clusters 2> /dev/null | tr -d '\r' || true
}

collect_running_clusters() {
  local found=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=1
    mark_running "$name"
  done < <(list_k3d_clusters)

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=1
    mark_running "$name"
  done < <(list_kind_clusters)

  if [ "$found" -eq 0 ]; then
    log_warn "未发现正在运行的 k3d/kind 集群"
  fi
}

PORTAINER_BASE=""
PORTAINER_JWT=""
PORTAINER_AVAILABLE=false

ensure_portainer_session() {
  if $PORTAINER_AVAILABLE; then
    return 0
  fi

  if ! command -v curl > /dev/null 2>&1; then
    log_warn "curl 未安装，无法访问 Portainer API"
    return 1
  fi

  PORTAINER_BASE=$("$ROOT_DIR/scripts/portainer.sh" api-base 2> /dev/null || true)
  if [ -z "$PORTAINER_BASE" ]; then
    log_warn "无法解析 Portainer API 地址"
    return 1
  fi

  add_no_proxy_host "$(host_from_url "$PORTAINER_BASE")"

  PORTAINER_JWT=$("$ROOT_DIR/scripts/portainer.sh" api-login 2> /dev/null || true)
  if [ -z "$PORTAINER_JWT" ]; then
    log_warn "Portainer 认证失败，跳过端点清理"
    return 1
  fi

  PORTAINER_AVAILABLE=true
  return 0
}

declare -a ENDPOINT_ROWS=()

parse_endpoints_with_python() {
  python3 - << 'PY'
import json, sys
payload = sys.stdin.read().strip() or '[]'
data = json.loads(payload)
for item in data:
    eid = str(item.get('Id', '') or '')
    name = str(item.get('Name', '') or '')
    status = str(item.get('Status', '') or '')
    url = str(item.get('URL', '') or '')
    etype = str(item.get('Type', '') or '')
    print('|'.join([eid, name, status, url, etype]))
PY
}

fetch_portainer_endpoints() {
  ENDPOINT_ROWS=()
  if ! ensure_portainer_session; then
    return 1
  fi

  local json
  json=$(curl -sk -H "Authorization: Bearer $PORTAINER_JWT" "$PORTAINER_BASE/api/endpoints" 2> /dev/null || true)
  if [ -z "$json" ]; then
    log_warn "未能获取 Portainer 端点列表"
    return 1
  fi

  while IFS='|' read -r eid name status url etype; do
    [ -n "$name" ] || continue
    ENDPOINT_ROWS+=("$eid|$name|$status|$url|$etype")
  done < <(printf '%s' "$json" | parse_endpoints_with_python)

  if [ "${#ENDPOINT_ROWS[@]}" -eq 0 ]; then
    log_warn "Portainer 中没有 Edge 端点"
    return 1
  fi
}

is_reserved_endpoint() {
  case "$1" in
    "" | dockerhost | local | local-docker | portainer | portainer-ce)
      return 0
      ;;
  esac
  return 1
}

delete_portainer_endpoint() {
  local eid="$1" name="$2"
  if $DRY_RUN; then
    log_info "DRY-RUN: 将删除 Portainer 端点 $name (ID $eid)"
    return 0
  fi

  if ! ensure_portainer_session; then
    return 1
  fi

  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $PORTAINER_JWT" "$PORTAINER_BASE/api/endpoints/$eid" || true)
  if [ "$code" = "200" ] || [ "$code" = "204" ] || [ "$code" = "404" ]; then
    return 0
  fi

  log_warn "删除 Portainer 端点 $name 失败 (HTTP $code)"
  return 1
}

summaries=()

record_summary() {
  summaries+=("$1")
}

cleanup_portainer() {
  fetch_portainer_endpoints || return 1

  local keep=0 stale=0 removed=0 skipped=0

  for row in "${ENDPOINT_ROWS[@]}"; do
    IFS='|' read -r eid name status url etype <<< "$row"
    [ -n "$name" ] || continue

    if ! is_reserved_endpoint "$name"; then
      if [ -n "${KEEP_MAP[$name]:-}" ]; then
        keep=$((keep + 1))
        if [ -n "${DESIRED_MAP[$name]:-}" ]; then
          printf '  ✓ 保留 %s (来源: SQLite)\n' "$name"
        else
          printf '  ✓ 保留 %s (来源: 实际集群)\n' "$name"
        fi
        continue
      fi
    else
      skipped=$((skipped + 1))
      printf '  ↺ 跳过系统端点 %s\n' "$name"
      continue
    fi

    stale=$((stale + 1))
    if delete_portainer_endpoint "$eid" "$name"; then
      removed=$((removed + 1))
      printf '  ✓ 删除残留端点 %s (ID %s)\n' "$name" "$eid"
    else
      printf '  ✗ 删除 Portainer 端点 %s 失败\n' "$name"
    fi
  done

  record_summary "portainer_keep=$keep stale=$stale removed=$removed skipped=$skipped"
}

run_prune_db() {
  if $DRY_RUN; then
    log_info "DRY-RUN: 仅展示 Portainer 操作，未执行 SQLite prune"
    return 0
  fi

  if [ ! -x "$ROOT_DIR/scripts/reconcile.sh" ]; then
    log_warn "reconcile.sh 不存在，无法执行 --prune-db"
    return 1
  fi

  log_info "调用 scripts/reconcile.sh --prune-missing 清理 SQLite"
  if "$ROOT_DIR/scripts/reconcile.sh" --prune-missing > /tmp/cleanup_prune.log 2>&1; then
    grep -E 'prune' /tmp/cleanup_prune.log || true
    record_summary "sqlite_prune=ok"
    rm -f /tmp/cleanup_prune.log || true
    return 0
  else
    log_warn "reconcile.sh --prune-missing 执行失败，详情见 /tmp/cleanup_prune.log"
    record_summary "sqlite_prune=failed"
    return 1
  fi
}

main() {
  log_info "开始校验 SQLite/集群/Portainer 漂移..."
  collect_desired_clusters || true
  collect_running_clusters || true

  cleanup_portainer || log_warn "Portainer 清理阶段出现问题（可能是无可用端点）"

  if $PRUNE_DB; then
    run_prune_db || log_warn "SQLite prune 未完成"
  fi

  log_info "摘要: ${summaries[*]:-无变化}"
  echo "cleanup_nonexistent_clusters.sh ✅ 完成"
}

main "$@"
