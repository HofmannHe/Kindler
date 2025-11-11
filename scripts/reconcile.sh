#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Final convergence after concurrent create/delete operations.
# Runs Git branch sync → ApplicationSet sync → HAProxy sync (single reload).
# Safe to run multiple times; idempotent.

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

main() {
  echo "[reconcile] Starting final convergence..."

  if [ -x "$ROOT_DIR/tools/git/sync_git_from_db.sh" ]; then
    echo "[reconcile] Syncing GitOps branches from DB..."
    "$ROOT_DIR/tools/git/sync_git_from_db.sh" 2>&1 | sed 's/^/  /' || true
  fi

  if [ -x "$ROOT_DIR/scripts/sync_applicationset.sh" ]; then
    echo "[reconcile] Syncing ArgoCD ApplicationSet..."
    "$ROOT_DIR/scripts/sync_applicationset.sh" 2>&1 | sed 's/^/  /' || true
  fi

  if [ -x "$ROOT_DIR/scripts/haproxy_sync.sh" ]; then
    echo "[reconcile] Reconciling HAProxy routes (with prune) ..."
    NO_RELOAD=0 "$ROOT_DIR/scripts/haproxy_sync.sh" --prune 2>&1 | sed 's/^/  /' || true
  fi

  echo "[reconcile] ✓ Done"
}

main "$@"

