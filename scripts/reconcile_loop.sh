#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Thin scheduling wrapper for scripts/reconcile.sh that supports looped execution and history summaries.
# Usage: scripts/reconcile_loop.sh [--interval <value>] [--max-runs <n>|--once] [reconcile-flags...]
# Category: gitops
# Status: experimental
# See also: scripts/reconcile.sh, tools/start_reconciler.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
RECONCILE_BIN="$ROOT_DIR/scripts/reconcile.sh"
if [ -z "${RECONCILE_LOOP_INTERVAL:-}" ] && [ -n "${RECONCILE_INTERVAL:-}" ]; then
  DEFAULT_INTERVAL_SPEC="${RECONCILE_INTERVAL}s"
else
  DEFAULT_INTERVAL_SPEC="${RECONCILE_LOOP_INTERVAL:-15m}"
fi
INTERVAL_SPEC="$DEFAULT_INTERVAL_SPEC"
LOOP_MAX_RUNS=0
PASSTHRU_ARGS=()
HISTORY_ARGS=()

usage() {
  cat << 'USAGE'
Usage: scripts/reconcile_loop.sh [options] [-- <reconcile args>]

Options:
  --interval <value>   Interval between runs (default: 15m). Accepts suffix s/m/h/d. Numbers without suffix assume minutes.
  --max-runs <n>       Stop after n runs (0 means infinite).
  --once               Convenience flag for --max-runs 1.
  --prune-missing      Passed through to scripts/reconcile.sh.
  --dry-run            Passed through (implies --from-db).
  --history-file PATH  Override history file passed to scripts/reconcile.sh and --last-run helper.
  -h, --help           Show this message.
  --                   Pass the remaining options directly to scripts/reconcile.sh.

Examples:
  scripts/reconcile_loop.sh --interval 10m --once          # Single reconcile pass
  scripts/reconcile_loop.sh --interval 5m --max-runs 3     # Run three times
  scripts/reconcile_loop.sh --interval 30s --prune-missing # Continuous reconcile with pruning
USAGE
}

parse_interval_seconds() {
  local spec="$1" value unit multiplier=60
  if [[ -z "$spec" ]]; then
    echo 900
    return 0
  fi
  if [[ "$spec" =~ ^([0-9]+)([sSmMhHdD]?)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      '' | m | M) multiplier=60 ;;
      s | S) multiplier=1 ;;
      h | H) multiplier=3600 ;;
      d | D) multiplier=86400 ;;
      *)
        echo "[reconcile-loop] ERROR: invalid interval unit '$unit'" >&2
        return 1
        ;;
    esac
    echo $((value * multiplier))
  else
    echo "[reconcile-loop] ERROR: invalid interval format '$spec'" >&2
    return 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)
      [ -n "${2:-}" ] || {
        echo "[reconcile-loop] ERROR: --interval requires a value" >&2
        exit 1
      }
      INTERVAL_SPEC="$2"
      shift 2
      ;;
    --interval=*)
      INTERVAL_SPEC="${1#*=}"
      shift
      ;;
    --once)
      LOOP_MAX_RUNS=1
      shift
      ;;
    --max-runs)
      [ -n "${2:-}" ] || {
        echo "[reconcile-loop] ERROR: --max-runs requires a value" >&2
        exit 1
      }
      LOOP_MAX_RUNS="$2"
      shift 2
      ;;
    --max-runs=*)
      LOOP_MAX_RUNS="${1#*=}"
      shift
      ;;
    --history-file)
      [ -n "${2:-}" ] || {
        echo "[reconcile-loop] ERROR: --history-file requires a path" >&2
        exit 1
      }
      HISTORY_ARGS=("--history-file" "$2")
      PASSTHRU_ARGS+=("--history-file" "$2")
      shift 2
      ;;
    --history-file=*)
      HISTORY_ARGS=("--history-file=${1#*=}")
      PASSTHRU_ARGS+=("--history-file=${1#*=}")
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        PASSTHRU_ARGS+=("$1")
        shift
      done
      break
      ;;
    --last-run | --json)
      echo "[reconcile-loop] ERROR: --last-run/--json are not supported here (invoke scripts/reconcile.sh directly)" >&2
      exit 1
      ;;
    *)
      PASSTHRU_ARGS+=("$1")
      shift
      ;;
  esac
done

if ! INTERVAL_SECONDS=$(parse_interval_seconds "$INTERVAL_SPEC"); then
  exit 1
fi

if [[ "$LOOP_MAX_RUNS" =~ ^[0-9]+$ ]]; then :; else
  echo "[reconcile-loop] ERROR: --max-runs expects a non-negative integer" >&2
  exit 1
fi

RECON_ARGS=(--from-db "${PASSTHRU_ARGS[@]}")
LOG_PREFIX="[reconcile-loop]"

run_counter=0

run_last_summary() {
  local human_tmp json_tmp
  human_tmp=$(mktemp)
  json_tmp=$(mktemp)
  local exit_code=0
  if "$RECONCILE_BIN" --last-run "${HISTORY_ARGS[@]}" > "$human_tmp" 2>&1; then
    while IFS= read -r line; do
      printf '%s %s\n' "$LOG_PREFIX" "$line"
    done < "$human_tmp"
  else
    exit_code=1
    printf '%s WARN: unable to read last-run summary (history file missing?)\n' "$LOG_PREFIX" >&2
  fi
  if "$RECONCILE_BIN" --last-run --json "${HISTORY_ARGS[@]}" > "$json_tmp" 2>&1; then
    local payload
    payload=$(cat "$json_tmp")
    printf '%s last-run-json: %s\n' "$LOG_PREFIX" "$payload"
  else
    printf '%s WARN: unable to obtain JSON summary\n' "$LOG_PREFIX" >&2
  fi
  rm -f "$human_tmp" "$json_tmp"
  return $exit_code
}

while :; do
  run_counter=$((run_counter + 1))
  printf '%s Run #%d started at %s (interval=%s, args=%s)\n' "$LOG_PREFIX" "$run_counter" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$INTERVAL_SPEC" "${RECON_ARGS[*]}"
  if ! env RECONCILE_SOURCE="${RECONCILE_SOURCE:-loop}" RECONCILE_INVOKER="${RECONCILE_INVOKER:-scripts/reconcile_loop.sh}" "$RECONCILE_BIN" "${RECON_ARGS[@]}"; then
    rc=$?
    printf '%s Run #%d failed (exit %d)\n' "$LOG_PREFIX" "$run_counter" "$rc" >&2
    exit $rc
  fi
  run_last_summary || true

  if [ "$LOOP_MAX_RUNS" -gt 0 ] && [ "$run_counter" -ge "$LOOP_MAX_RUNS" ]; then
    printf '%s Completed %d run(s); exiting.\n' "$LOG_PREFIX" "$run_counter"
    break
  fi

  printf '%s Sleeping %s before next run...\n' "$LOG_PREFIX" "$INTERVAL_SECONDS"
  sleep "$INTERVAL_SECONDS"
done
