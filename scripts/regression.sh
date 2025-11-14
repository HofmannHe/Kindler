#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Canonical entrypoint for the scripted regression harness (clean → bootstrap → reconcile → smoke/tests).
# Usage: scripts/regression.sh [--full|--skip-clean|--skip-bootstrap|--clusters a,b]
# Category: testing
# Status: stable
# See also: tests/regression_test.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

if [ $# -eq 0 ]; then
  set -- --full
fi

exec "$ROOT_DIR/tests/regression_test.sh" "$@"
