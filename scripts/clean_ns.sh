#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"
usage(){ echo "Usage: KINDLER_NS=<ns> $0 [--from-csv] [env1 [env2 ...]]" >&2; exit 1; }
[ -n "${KINDLER_NS:-}" ] || { echo "KINDLER_NS is required to avoid touching master resources" >&2; exit 2; }
from_csv=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from-csv) from_csv=1; shift ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done
envs=("$@")
if [ $from_csv -eq 1 ] || [ ${#envs[@]} -eq 0 ]; then
  if [ -f "$ROOT_DIR/config/environments.csv" ]; then
    mapfile -t envs < <(awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" | grep -v '^devops$')
  else
    echo "no environments.csv, nothing to do" >&2; exit 0
  fi
fi
echo "[NS-CLEAN] namespace: $KINDLER_NS"
for env in "${envs[@]}"; do
  [ -n "$env" ] || continue
  provider="$(provider_for "$env")" || provider=kind
  eff="$(effective_name "$env")"
  echo "[NS-CLEAN] env=$env eff=$eff provider=$provider"
  "$ROOT_DIR"/scripts/haproxy_route.sh remove "$env" || true
  "$ROOT_DIR"/scripts/argocd_register.sh unregister "$env" "$provider" || true
  ep_name="$(echo "$eff" | tr -d '-')"
  "$ROOT_DIR"/scripts/portainer.sh del-endpoint "$ep_name" >/dev/null 2>&1 || true
  PROVIDER="$provider" "$ROOT_DIR"/scripts/cluster.sh delete "$env" || true
done
echo "[NS-CLEAN] done"
