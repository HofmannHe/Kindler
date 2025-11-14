#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Validate SQLite cluster records against actual Kubernetes contexts and optionally prune stale rows.
# Usage: scripts/db_verify.sh [--cleanup-missing] [--json-summary]
# Category: diagnostics
# Status: stable
# See also: scripts/test_data_consistency.sh, scripts/check_consistency.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

usage() {
  cat << 'USAGE'
Usage: scripts/db_verify.sh [--cleanup-missing] [--json-summary]

Options:
  --cleanup-missing   Remove database rows whose corresponding clusters no longer exist (skips devops)
  --json-summary      Emit a machine-readable JSON summary (prefixed with DB_VERIFY_SUMMARY=...)
  -h, --help          Show this help message
USAGE
}

cleanup_missing=false
emit_json=false
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup-missing)
      cleanup_missing=true
      shift
      ;;
    --json-summary)
      emit_json=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

escape_sql() {
  printf "%s" "$1" | sed "s/'/''/g"
}

echo "=========================================="
echo "  SQLite Cluster Verification"
echo "=========================================="

if ! sqlite_is_available > /dev/null 2>&1; then
  echo "✗ SQLite database is not reachable (container offline?)" >&2
  exit 1
fi

clusters=$(sqlite_query "SELECT name, provider, desired_state, actual_state, status FROM clusters ORDER BY name;" 2> /dev/null || true)

if [ -z "$clusters" ]; then
  echo "ℹ No clusters recorded in SQLite"
  exit 0
fi

total=0
missing=0
mismatched_state=0
declare -a SUMMARY_ROWS=()

printf "%-18s %-6s %-12s %-12s %-10s %-8s\n" "Cluster" "Type" "Desired" "Actual" "Status" "Result"
printf -- "%.0s-" {1..70}
printf '\n'

while IFS='|' read -r name provider desired actual status; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  ctx=""
  if [ "$provider" = "k3d" ]; then
    ctx="k3d-${name}"
  else
    ctx="kind-${name}"
  fi

  cluster_ok=true
  if ! kubectl --context "$ctx" get nodes > /dev/null 2>&1; then
    cluster_ok=false
    missing=$((missing + 1))
  fi

  state_ok=true
  if $cluster_ok; then
    if [ "${desired:-present}" != "present" ]; then
      state_ok=false
    fi
  else
    if [ "${desired:-present}" = "present" ]; then
      state_ok=false
    fi
  fi
  if ! $state_ok; then
    mismatched_state=$((mismatched_state + 1))
  fi

  result="OK"
  if ! $cluster_ok; then
    result="MISSING"
  elif ! $state_ok; then
    result="DRIFT"
  fi

  SUMMARY_ROWS+=("$name|$provider|${desired:-?}|${actual:-?}|${status:-?}|$result")

  printf "%-18s %-6s %-12s %-12s %-10s %-8s\n" "$name" "$provider" "${desired:-?}" "${actual:-?}" "${status:-?}" "$result"

  if ! $cluster_ok && $cleanup_missing && [ "$name" != "devops" ]; then
    esc_name="$(escape_sql "$name")"
    sqlite_transaction "DELETE FROM clusters WHERE name='${esc_name}';" > /dev/null 2>&1 || true
    echo "    • Removed stale DB record: $name"
  fi
done < <(echo "$clusters")

echo "------------------------------------------"
echo "Total records : $total"
echo "Missing ctx   : $missing"
echo "State drift   : $mismatched_state"

if $emit_json; then
  if command -v python3 > /dev/null 2>&1; then
    summary_payload=$(printf '%s\n' "${SUMMARY_ROWS[@]}")
    json=$(
      DB_VERIFY_ROWS="$summary_payload" python3 - << 'PY'
import json, os
rows = [line.strip() for line in os.environ.get("DB_VERIFY_ROWS", "").splitlines() if line.strip()]
items = []
for row in rows:
    parts = row.split('|')
    while len(parts) < 6:
        parts.append('')
    name, provider, desired, actual, status, result = parts[:6]
    items.append({
        "name": name,
        "provider": provider,
        "desired": desired,
        "actual": actual,
        "status": status,
        "result": result,
    })
summary = {
    "total": len(items),
    "missing": len([i for i in items if i["result"] == "MISSING"]),
    "drift": len([i for i in items if i["result"] == "DRIFT"]),
    "records": items,
}
print(json.dumps(summary, ensure_ascii=False))
PY
    )
    echo "DB_VERIFY_SUMMARY=${json}"
  else
    echo "DB_VERIFY_SUMMARY={\"total\":${total},\"missing\":${missing},\"drift\":${mismatched_state}}"
  fi
fi

if [ $missing -eq 0 ] && [ $mismatched_state -eq 0 ]; then
  echo "✓ DB verification passed"
  exit 0
fi

echo "✗ DB verification found issues" >&2
if [ $missing -gt 0 ]; then
  exit 10
fi
exit 11
