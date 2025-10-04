#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CFG="$ROOT_DIR/compose/haproxy/haproxy.cfg"

usage() {
  cat >&2 <<USAGE
Usage: $0 [--prune]

说明：
- 从 config/environments.csv 读取环境列表与 node_port，批量调用 haproxy_route.sh add 进行同步。
- 指定 --prune 时，会移除 haproxy.cfg 中存在但 CSV 中缺失的环境路由。
USAGE
}

prune=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prune) prune=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

csv="$ROOT_DIR/config/environments.csv"
[ -f "$csv" ] || { echo "[sync] CSV not found: $csv" >&2; exit 1; }

# read env and node_port from CSV
mapfile -t envs < <(awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1}' "$csv")
mapfile -t ports < <(awk -F, '$0 !~ /^\s*#/ && NF>0 {print $3}' "$csv")

if [ ${#envs[@]} -eq 0 ]; then
  echo "[sync] no environments found in CSV" >&2
  exit 0
fi

echo "[sync] adding/updating routes from CSV..."
for i in "${!envs[@]}"; do
  n="${envs[$i]}"; p="${ports[$i]:-30080}"
  [ -n "$n" ] || continue
  "$ROOT_DIR"/scripts/haproxy_route.sh add "$n" --node-port "$p" || true
done

if [ $prune -eq 1 ]; then
  echo "[sync] pruning routes not present in CSV..."
  # collect existing env names from haproxy.cfg (host_ and backend be_)
  mapfile -t exist < <(awk '/# BEGIN DYNAMIC ACL/{f=1;next} /# END DYNAMIC ACL/{f=0} f && /acl host_/ {for(i=1;i<=NF;i++){ if($i ~ /^host_/){sub("host_","",$i); print $i}} }' "$CFG" | sort -u)
  for e in "${exist[@]}"; do
    keep=0
    for n in "${envs[@]}"; do [ "$e" = "$n" ] && { keep=1; break; }; done
    if [ $keep -eq 0 ]; then
      "$ROOT_DIR"/scripts/haproxy_route.sh remove "$e" || true
    fi
  done
fi

echo "[sync] done"
