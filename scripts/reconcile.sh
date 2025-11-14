#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Declarative reconciliation entrypoint that converges SQLite desired state and final sync steps.
# Usage: scripts/reconcile.sh [--from-db] [--dry-run] [--prune-missing]
# Category: gitops
# Status: stable
# See also: scripts/reconciler.sh, scripts/create_env.sh, scripts/delete_env.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

ORIGINAL_ARGS=("$@")
START_EPOCH=$(date +%s)
RECONCILE_SOURCE="${RECONCILE_SOURCE:-manual}"
RECONCILE_INVOKER="${RECONCILE_INVOKER:-scripts/reconcile.sh}"
DEFAULT_HISTORY_FILE="$ROOT_DIR/logs/reconcile_history.jsonl"
HISTORY_FILE="${RECONCILE_HISTORY_FILE:-$DEFAULT_HISTORY_FILE}"
ENABLE_HISTORY_LOG=true
SHOW_LAST_RUN=false
LAST_RUN_JSON=false
SUMMARY_JSON="[]"
HISTORY_WARNED=false
RUN_STARTED=false

case "$HISTORY_FILE" in
  /*) : ;;
  *) HISTORY_FILE="$ROOT_DIR/$HISTORY_FILE" ;;
esac

trap 'rc=$?; if $RUN_STARTED; then append_history_entry "$rc" || true; fi' EXIT

usage() {
  cat << 'USAGE'
Usage: scripts/reconcile.sh [options]

Options:
  --from-db             Read desired state from SQLite and create/delete clusters to match it.
  --dry-run             Plan actions without mutating resources (implies --from-db). Exits non-zero when drift exists.
  --prune-missing       Remove SQLite rows for clusters that no longer exist (skips devops).
  --history-file <path> Override reconcile history JSONL path (default: logs/reconcile_history.jsonl).
  --last-run            Print the most recent history entry and exit (combine with --json for raw output).
  --json                When used with --last-run, output only the JSON entry (no formatting).
  -h, --help            Show this help message.

Examples:
  scripts/reconcile.sh --from-db
  scripts/reconcile.sh --dry-run
  scripts/reconcile.sh --prune-missing
  scripts/reconcile.sh --last-run --json
USAGE
}

print_last_run() {
  local file="$HISTORY_FILE"
  if [ ! -f "$file" ] || ! grep -vq '^[[:space:]]*$' "$file" > /dev/null 2>&1; then
    echo "[reconcile] No history entries found at $file" >&2
    exit 2
  fi
  local entry
  entry=$(grep -v '^[[:space:]]*$' "$file" | tail -n 1)
  if [ -z "$entry" ]; then
    echo "[reconcile] History file exists but contains no entries" >&2
    exit 2
  fi
  if $LAST_RUN_JSON; then
    printf '%s\n' "$entry"
    return 0
  fi
  if command -v python3 > /dev/null 2>&1; then
    RECON_LAST_ENTRY="$entry" python3 - << 'PY'
import json, os
try:
    data = json.loads(os.environ.get("RECON_LAST_ENTRY", ""))
except json.JSONDecodeError:
    print(os.environ.get("RECON_LAST_ENTRY", ""))
else:
    summary = data.get("summary", [])
    print(f"Last reconcile run: {data.get('timestamp')} (source={data.get('source')})")
    print(f"  invoker : {data.get('invoker')}")
    print(f"  exit    : {data.get('exit_code')} (duration {data.get('duration_seconds')}s)")
    print(f"  args    : {' '.join(data.get('args') or [])}")
    print(f"  counts  : plan={data.get('plan_count')} exec={data.get('executed_count')} failed={data.get('failed_count')} pruned={data.get('pruned_count')}")
    if summary:
        print("  summary :")
        for item in summary:
            print(f"    - {item.get('name')} [{item.get('provider')}]: {item.get('action')} -> {item.get('result')} ({item.get('message')})")
PY
  else
    printf '%s\n' "$entry"
  fi
}

append_history_entry() {
  $ENABLE_HISTORY_LOG || return 0
  if ! command -v python3 > /dev/null 2>&1; then
    if ! $HISTORY_WARNED; then
      log_warn "python3 not available; skipping reconcile history logging"
      HISTORY_WARNED=true
    fi
    return 0
  fi

  local exit_code="$1"
  local timestamp duration args_payload lock_file history_dir
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  duration=$(($(date +%s) - START_EPOCH))
  if [ "${#ORIGINAL_ARGS[@]}" -gt 0 ]; then
    args_payload=$(printf '%s\n' "${ORIGINAL_ARGS[@]}")
  else
    args_payload=""
  fi
  history_dir=$(dirname -- "$HISTORY_FILE")
  mkdir -p "$history_dir"
  lock_file="${HISTORY_FILE}.lock"

  local from_flag dry_flag prune_flag
  $FROM_DB && from_flag=true || from_flag=false
  $DRY_RUN && dry_flag=true || dry_flag=false
  $PRUNE_MISSING && prune_flag=true || prune_flag=false

  local entry
  entry=$(
    RECON_TS="$timestamp" \
      RECON_DURATION="$duration" \
      RECON_EXIT="$exit_code" \
      RECON_SOURCE="$RECONCILE_SOURCE" \
      RECON_INVOKER="$RECONCILE_INVOKER" \
      RECON_ARGS="$args_payload" \
      RECON_SUMMARY="$SUMMARY_JSON" \
      RECON_PLAN_COUNT="$PLAN_COUNT" \
      RECON_EXECUTED="$EXECUTED_COUNT" \
      RECON_FAILED="$FAILED_COUNT" \
      RECON_PRUNED="$PRUNED_COUNT" \
      RECON_FROM_DB="$from_flag" \
      RECON_DRY_RUN="$dry_flag" \
      RECON_PRUNE="$prune_flag" \
      RECON_HISTORY_FILE="$HISTORY_FILE" \
      python3 - << 'PY'
import json, os
entry = {
    "timestamp": os.environ.get("RECON_TS"),
    "duration_seconds": int(os.environ.get("RECON_DURATION", "0")),
    "exit_code": int(os.environ.get("RECON_EXIT", "0")),
    "source": os.environ.get("RECON_SOURCE"),
    "invoker": os.environ.get("RECON_INVOKER"),
    "history_file": os.environ.get("RECON_HISTORY_FILE"),
    "args": [line for line in os.environ.get("RECON_ARGS", "").splitlines() if line],
    "from_db": os.environ.get("RECON_FROM_DB") == "true",
    "dry_run": os.environ.get("RECON_DRY_RUN") == "true",
    "prune_missing": os.environ.get("RECON_PRUNE") == "true",
    "plan_count": int(os.environ.get("RECON_PLAN_COUNT", "0")),
    "executed_count": int(os.environ.get("RECON_EXECUTED", "0")),
    "failed_count": int(os.environ.get("RECON_FAILED", "0")),
    "pruned_count": int(os.environ.get("RECON_PRUNED", "0")),
}
summary_raw = os.environ.get("RECON_SUMMARY", "[]") or "[]"
try:
    entry["summary"] = json.loads(summary_raw)
except json.JSONDecodeError:
    entry["summary"] = []
print(json.dumps(entry, ensure_ascii=False))
PY
  ) || return 0

  (
    umask 077
    exec 212> "$lock_file"
    flock 212
    printf '%s\n' "$entry" >> "$HISTORY_FILE"
  ) || log_warn "Failed to append reconcile history at $HISTORY_FILE"
}

FROM_DB=false
DRY_RUN=false
PRUNE_MISSING=false

PLAN_COUNT=0
FAILED_COUNT=0
EXECUTED_COUNT=0
PRUNED_COUNT=0

declare -a SUMMARY_ROWS=()

log_info() { printf '[reconcile] %s\n' "$*"; }
log_warn() { printf '[reconcile] WARN: %s\n' "$*" >&2; }
log_error() { printf '[reconcile] ERROR: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from-db)
      FROM_DB=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      FROM_DB=true
      shift
      ;;
    --prune-missing)
      PRUNE_MISSING=true
      shift
      ;;
    --history-file)
      if [ -z "${2:-}" ]; then
        log_error "--history-file requires a path"
        exit 1
      fi
      HISTORY_FILE="$2"
      case "$HISTORY_FILE" in
        /*) : ;;
        *) HISTORY_FILE="$ROOT_DIR/$HISTORY_FILE" ;;
      esac
      shift 2
      ;;
    --history-file=*)
      HISTORY_FILE="${1#*=}"
      case "$HISTORY_FILE" in
        /*) : ;;
        *) HISTORY_FILE="$ROOT_DIR/$HISTORY_FILE" ;;
      esac
      shift
      ;;
    --last-run)
      SHOW_LAST_RUN=true
      shift
      ;;
    --json)
      LAST_RUN_JSON=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if $LAST_RUN_JSON && ! $SHOW_LAST_RUN; then
  echo "[reconcile] ERROR: --json can only be used together with --last-run" >&2
  exit 1
fi

if $SHOW_LAST_RUN; then
  ENABLE_HISTORY_LOG=false
  print_last_run
  exit 0
fi

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

update_cluster_record() {
  local name="$1"
  local actual="$2"
  local status="$3"
  local err_msg="${4:-}"

  local esc_name esc_status esc_actual err_clause
  esc_name="$(sql_escape "$name")"
  esc_status="$(sql_escape "${status:-unknown}")"
  esc_actual="$(sql_escape "${actual:-unknown}")"

  if [ -n "$err_msg" ]; then
    err_clause="reconcile_error='$(sql_escape "$err_msg")'"
  else
    err_clause="reconcile_error=NULL"
  fi

  sqlite_transaction "
    UPDATE clusters
       SET actual_state='${esc_actual}',
           status='${esc_status}',
           last_reconciled_at=datetime('now'),
           ${err_clause}
     WHERE name='${esc_name}';
  " > /dev/null 2>&1 || true
}

K3D_CACHE=""
KIND_CACHE=""

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

refresh_cluster_cache() {
  K3D_CACHE="$(list_k3d_clusters)"
  KIND_CACHE="$(list_kind_clusters)"
}

cluster_exists() {
  local name="$1"
  local provider="$2"
  case "$provider" in
    k3d)
      printf '%s\n' "$K3D_CACHE" | grep -Fxq "$name"
      ;;
    kind)
      printf '%s\n' "$KIND_CACHE" | grep -Fxq "$name"
      ;;
    *)
      return 1
      ;;
  esac
}

record_summary() {
  local name="$1"
  local provider="$2"
  local desired="$3"
  local actual="$4"
  local action="$5"
  local result="$6"
  local message="${7:-}"
  SUMMARY_ROWS+=("$name|$provider|$desired|$actual|$action|$result|$message")
}

ensure_sqlite_online() {
  if ! sqlite_is_available > /dev/null 2>&1; then
    log_error "SQLite database is not reachable (is kindler-webui-backend running?)"
    exit 2
  fi
}

plan_or_run() {
  local type="$1"
  local name="$2"
  local provider="$3"
  local node_port="$4"
  local pf_port="$5"
  local http_port="$6"
  local https_port="$7"
  local action_label result_label message log_file
  local max_attempts=1
  if [ "$type" = "create" ]; then
    max_attempts=2
  fi

  action_label="$type"
  log_file="/tmp/reconcile_${type}_${name}.log"

  if $DRY_RUN; then
    PLAN_COUNT=$((PLAN_COUNT + 1))
    record_summary "$name" "$provider" "-" "-" "$action_label" "planned" "dry-run"
    return 0
  fi

  local attempt=1
  local success=false
  while [ $attempt -le $max_attempts ]; do
    local -a cmd=("$ROOT_DIR/scripts/${type}_env.sh" -n "$name")
    if [ "$type" = "create" ]; then
      cmd=("$ROOT_DIR/scripts/create_env.sh" -n "$name" -p "$provider")
      [ -n "${node_port:-}" ] && cmd+=(--node-port "$node_port")
      [ -n "${pf_port:-}" ] && cmd+=(--pf-port "$pf_port")
      [ -n "${http_port:-}" ] && cmd+=(--http-port "$http_port")
      [ -n "${https_port:-}" ] && cmd+=(--https-port "$https_port")
    fi

    if "${cmd[@]}" > "$log_file" 2>&1; then
      success=true
      break
    fi

    if [ $attempt -lt $max_attempts ]; then
      log_warn "Action '${action_label}' for ${name} failed (attempt ${attempt}/${max_attempts}); retrying in 5s..."
      sleep 5
    fi
    attempt=$((attempt + 1))
  done

  if $success; then
    EXECUTED_COUNT=$((EXECUTED_COUNT + 1))
    if [ "$type" = "create" ]; then
      refresh_cluster_cache
      if cluster_exists "$name" "$provider"; then
        update_cluster_record "$name" "running" "Ready" ""
        result_label="created"
        message="cluster online"
      else
        result_label="warning"
        message="create succeeded but cluster not detected"
        update_cluster_record "$name" "unknown" "Warning" "$message"
      fi
    else
      refresh_cluster_cache
      update_cluster_record "$name" "absent" "Removed" ""
      result_label="deleted"
      message="cluster removed"
    fi
    record_summary "$name" "$provider" "-" "-" "$action_label" "$result_label" "$message"
    return 0
  fi

  FAILED_COUNT=$((FAILED_COUNT + 1))
  local tail_log
  tail_log=$(tail -20 "$log_file" 2> /dev/null | tr '\n' ' ')
  record_summary "$name" "$provider" "-" "-" "$action_label" "error" "${tail_log:-command failed}"
  update_cluster_record "$name" "failed" "Failed" "$tail_log"
  log_error "Action '${action_label}' for ${name} failed (see $log_file)"
  return 1
}

prune_missing_records() {
  local rows removed=0
  rows=$(sqlite_query "
    SELECT name, provider
      FROM clusters
     WHERE name != 'devops'
     ORDER BY name;
  " 2> /dev/null || true)

  [ -z "$rows" ] && return 0

  while IFS='|' read -r name provider; do
    [ -z "$name" ] && continue
    provider="${provider:-k3d}"
    if cluster_exists "$name" "$provider"; then
      continue
    fi

    if $DRY_RUN; then
      PLAN_COUNT=$((PLAN_COUNT + 1))
      record_summary "$name" "$provider" "-" "missing" "prune" "planned" "would remove SQLite row"
    else
      sqlite_transaction "DELETE FROM clusters WHERE name='$(sql_escape "$name")';" > /dev/null 2>&1 || true
      removed=$((removed + 1))
      PRUNED_COUNT=$((PRUNED_COUNT + 1))
      record_summary "$name" "$provider" "-" "missing" "prune" "done" "removed stale DB row"
    fi
  done < <(printf '%s\n' "$rows")

  return 0
}

reconcile_from_database() {
  local rows
  rows=$(sqlite_query "
    SELECT name, provider, COALESCE(desired_state,'present'), COALESCE(actual_state,'unknown'),
           COALESCE(node_port,''), COALESCE(pf_port,''), COALESCE(http_port,''), COALESCE(https_port,'')
      FROM clusters
     WHERE name != 'devops'
     ORDER BY name;
  " 2> /dev/null || true)

  if [ -z "$rows" ]; then
    log_warn "No business clusters recorded in SQLite."
    return 0
  fi

  while IFS='|' read -r name provider desired actual node_port pf_port http_port https_port; do
    [ -z "$name" ] && continue
    provider="${provider:-k3d}"
    desired="${desired:-present}"
    actual="${actual:-unknown}"
    [ "$node_port" = "NULL" ] && node_port=""
    [ "$pf_port" = "NULL" ] && pf_port=""
    [ "$http_port" = "NULL" ] && http_port=""
    [ "$https_port" = "NULL" ] && https_port=""

    local exists=0
    if cluster_exists "$name" "$provider"; then
      exists=1
    fi

    if [ "$desired" = "present" ] && [ "$exists" -eq 0 ]; then
      log_info "Cluster '$name' missing (provider=$provider) -> create"
      plan_or_run "create" "$name" "$provider" "$node_port" "$pf_port" "$http_port" "$https_port" || true
      continue
    fi

    if [ "$desired" = "absent" ] && [ "$exists" -eq 1 ]; then
      log_info "Cluster '$name' desired absent but exists -> delete"
      plan_or_run "delete" "$name" "$provider" "" "" "" "" || true
      continue
    fi

    if [ "$desired" = "present" ] && [ "$exists" -eq 1 ]; then
      update_cluster_record "$name" "running" "Ready" ""
      record_summary "$name" "$provider" "$desired" "running" "noop" "ok" "cluster healthy"
      continue
    fi

    if [ "$desired" = "absent" ] && [ "$exists" -eq 0 ]; then
      update_cluster_record "$name" "absent" "Removed" ""
      record_summary "$name" "$provider" "$desired" "absent" "noop" "ok" "already absent"
      continue
    fi

    # Unknown desired states: record but no action
    record_summary "$name" "$provider" "$desired" "$actual" "noop" "skipped" "unhandled desired_state"
  done < <(printf '%s\n' "$rows")
}

render_summary() {
  local total="${#SUMMARY_ROWS[@]}"
  if [ "$total" -eq 0 ]; then
    echo "[reconcile] Summary: no actions recorded."
    return
  fi

  printf "\n%-18s %-6s %-8s %-8s %-10s %-10s %s\n" "Cluster" "Prov" "Desired" "Actual" "Action" "Result" "Message"
  printf -- "%.0s-" {1..90}
  printf '\n'
  printf '%s\n' "${SUMMARY_ROWS[@]}" | while IFS='|' read -r name provider desired actual action result message; do
    printf "%-18s %-6s %-8s %-8s %-10s %-10s %s\n" "$name" "$provider" "$desired" "$actual" "$action" "$result" "$message"
  done

  if command -v python3 > /dev/null 2>&1; then
    local summary_payload json
    summary_payload=$(printf '%s\n' "${SUMMARY_ROWS[@]}")
    json=$(
      RECON_ROWS="$summary_payload" python3 - << 'PY'
import json, os
rows = [line.strip() for line in os.environ.get("RECON_ROWS", "").splitlines() if line.strip()]
items = []
for row in rows:
    parts = row.split('|')
    while len(parts) < 7:
        parts.append('')
    name, provider, desired, actual, action, result, message = parts[:7]
    items.append({
        "name": name,
        "provider": provider,
        "desired": desired,
        "actual": actual,
        "action": action,
        "result": result,
        "message": message,
    })
print(json.dumps(items, ensure_ascii=False))
PY
    )
    SUMMARY_JSON="$json"
    printf "\nRECONCILE_SUMMARY=%s\n" "$json"
  fi
}

run_final_sync() {
  log_info "Starting final convergence steps..."

  if [ -x "$ROOT_DIR/tools/git/sync_git_from_db.sh" ]; then
    log_info "Syncing GitOps branches from DB..."
    "$ROOT_DIR/tools/git/sync_git_from_db.sh" 2>&1 | sed 's/^/  /' || true
  fi

  if [ -x "$ROOT_DIR/scripts/sync_applicationset.sh" ]; then
    log_info "Syncing ArgoCD ApplicationSet..."
    "$ROOT_DIR/scripts/sync_applicationset.sh" 2>&1 | sed 's/^/  /' || true
  fi

  if [ -x "$ROOT_DIR/scripts/haproxy_sync.sh" ]; then
    log_info "Reconciling HAProxy routes (with prune)..."
    NO_RELOAD=0 "$ROOT_DIR/scripts/haproxy_sync.sh" --prune 2>&1 | sed 's/^/  /' || true
  fi

  log_info "Final convergence complete."
}

main() {
  RUN_STARTED=true
  local exit_code=0

  if $FROM_DB || $PRUNE_MISSING; then
    ensure_sqlite_online
    refresh_cluster_cache
  fi

  if $PRUNE_MISSING; then
    if $FROM_DB; then
      log_warn "--prune-missing runs before --from-db; stale rows will be removed and not recreated."
    fi
    prune_missing_records
  fi

  if $FROM_DB; then
    reconcile_from_database
  fi

  render_summary

  if $DRY_RUN; then
    if [ "$PLAN_COUNT" -gt 0 ]; then
      log_warn "Dry-run detected $PLAN_COUNT pending action(s); exiting with non-zero status."
      exit 3
    fi
    exit 0
  fi

  if [ "$FAILED_COUNT" -gt 0 ]; then
    log_error "$FAILED_COUNT action(s) failed during reconciliation."
    exit_code=1
  fi

  if $FROM_DB || $PRUNE_MISSING; then
    refresh_cluster_cache
    local verify_attempt=0 verify_rc=0
    while [ $verify_attempt -lt 3 ]; do
      if "$ROOT_DIR/scripts/db_verify.sh" --json-summary > /dev/null 2>&1; then
        verify_rc=0
        break
      fi
      verify_rc=$?
      verify_attempt=$((verify_attempt + 1))
      log_warn "db_verify reported drift (exit=${verify_rc}), retrying in 5s..."
      sleep 5
    done
    if [ $verify_rc -eq 0 ]; then
      log_info "SQLite vs cluster verification passed."
    else
      exit_code=$verify_rc
      log_error "db_verify reported drift (exit=$exit_code)."
    fi
  fi

  if [ "$exit_code" -eq 0 ]; then
    run_final_sync
  fi

  exit "$exit_code"
}

main "$@"
