#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 兼容旧测试入口：委派到 scripts/test_data_consistency.sh
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec "$ROOT_DIR/scripts/test_data_consistency.sh" "$@"
