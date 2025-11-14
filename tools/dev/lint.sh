#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Run lightweight shell lint/format checks if tools are available.
# Usage: tools/dev/lint.sh [--fix]

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
FIX=0
case "${1:-}" in
  --fix) FIX=1 ;;
  "" ) : ;;
  *) echo "Usage: $0 [--fix]" >&2; exit 2 ;;
esac

shfmt_cmd=""
if command -v shfmt >/dev/null 2>&1; then
  shfmt_cmd="shfmt"
  SHFMT_OPTS=(-i 2 -ci -bn -sr)
else
  echo "[lint] shfmt not found (skip)" >&2
fi

shellcheck_cmd=""
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_cmd="shellcheck"
else
  echo "[lint] shellcheck not found (skip)" >&2
fi

targets=(scripts/*.sh)

if [ -n "$shfmt_cmd" ]; then
  if [ $FIX -eq 1 ]; then
    echo "[lint] shfmt -w scripts/*.sh"
    $shfmt_cmd "${SHFMT_OPTS[@]}" -w "${targets[@]}"
  else
    echo "[lint] shfmt -d scripts/*.sh"
    $shfmt_cmd "${SHFMT_OPTS[@]}" -d "${targets[@]}" || true
  fi
fi

if [ -n "$shellcheck_cmd" ]; then
  echo "[lint] shellcheck scripts/*.sh"
  $shellcheck_cmd -x -S style -s bash "${targets[@]}" || true
fi

echo "[lint] done"
