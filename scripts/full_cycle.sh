#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
  cat >&2 <<USAGE
用法: $0 [--dry-run] [--concurrency N]

说明:
- 从 clean 开始，拉起基础设施 (bootstrap)，然后按 CSV 批量创建业务环境，最后同步 HAProxy 路由并冒烟验证。
- 要求 CSV 中至少包含 3 个 kind 与 3 个 k3d 环境（不含 devops）。
USAGE
}

dry=0
concurrency=3
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --concurrency) concurrency="$2"; shift 2 ;;
    --concurrency=*) concurrency="${1#--concurrency=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

export DRY_RUN="$dry"

ts() { date +%s; }
fmtsec() { awk -v s="$1" 'BEGIN{printf "%.1fs", s+0}'; }
time_section() {
  local label="$1" start end dur; shift
  start=$(ts)
  "$@"
  end=$(ts); dur=$((end-start))
  echo "[TIME] ${label}: $(fmtsec "$dur")"
}
total_start=$(ts)

report_file="$ROOT_DIR/docs/TEST_REPORT.md"
printf '\n## Full Cycle Run @ %s\n' "$(date -Is)" >>"$report_file"

csv="$ROOT_DIR/config/environments.csv"
[ -f "$csv" ] || { echo "[FULL] 未找到 $csv" >&2; exit 1; }

echo "[FULL] 1/5 清理环境(clean)"
time_section clean "$ROOT_DIR/scripts/clean.sh" || true
echo "- phase(clean): done" >>"$report_file"

echo "[FULL] 2/5 启动基础设施(bootstrap)"
time_section bootstrap "$ROOT_DIR/scripts/bootstrap.sh"
echo "- phase(bootstrap): done" >>"$report_file"

echo "[FULL] 3/5 读取 CSV 并选择业务环境"
mapfile -t rows < <(awk -F, '$0 !~ /^\s*#/ && NF>=2 {print $1","$2","$3","$6}' "$csv" | grep -v '^devops,')

# 统计数量并校验
kind_selected=()
k3d_selected=()
for r in "${rows[@]}"; do
  IFS=, read -r env provider node_port haproxy_route <<<"$r"
  IFS=$'\n\t'
  # 仅选择 haproxy_route 为真 (或为空默认真) 的环境
  flag=$(echo "${haproxy_route:-true}" | tr 'A-Z' 'a-z')
  case "$flag" in 0|no|false|off) continue ;; esac
  if [ "$provider" = "kind" ] && [ ${#kind_selected[@]} -lt 3 ]; then
    kind_selected+=("$env")
  elif [ "$provider" = "k3d" ] && [ ${#k3d_selected[@]} -lt 3 ]; then
    k3d_selected+=("$env")
  fi
done

if [ ${#kind_selected[@]} -lt 3 ] || [ ${#k3d_selected[@]} -lt 3 ]; then
  echo "[FULL] CSV 中的环境不足: kind=${#kind_selected[@]} k3d=${#k3d_selected[@]} (至少 3+3)" >&2
  echo "[FULL] 请在 config/environments.csv 中补齐条目后重试" >&2
  exit 2
fi

echo "[FULL] 将创建如下环境 (NodePort 统一):"
printf '  kind: %s\n' "${kind_selected[@]}"
printf '  k3d: %s\n' "${k3d_selected[@]}"

echo "[FULL] 4/5 创建业务环境并注册 Portainer/ArgoCD (并发=${concurrency})"
mkdir -p "$ROOT_DIR/data/times"
rm -f "$ROOT_DIR/data/times"/*.time 2>/dev/null || true

spawn_env() {
  local env="$1"
  echo "[FULL] -> ${env}"
  local s; s=$(ts)
  if command -v timeout >/dev/null 2>&1; then
    timeout -s TERM "${CREATE_TIMEOUT:-900}" "$ROOT_DIR/scripts/create_env.sh" -n "$env" || echo "[WARN] create_env timeout for ${env}"
  else
    "$ROOT_DIR/scripts/create_env.sh" -n "$env"
  fi
  local d; d=$(( $(ts) - s ))
  echo "$d" >"$ROOT_DIR/data/times/${env}.time"
}

running=0
for e in "${kind_selected[@]}" "${k3d_selected[@]}"; do
  spawn_env "$e" &
  running=$((running+1))
  if [ "$running" -ge "$concurrency" ]; then
    wait -n || true
    running=$((running-1))
  fi
done
wait || true

echo "[FULL] 同步 HAProxy 路由"
"$ROOT_DIR/scripts/haproxy_sync.sh" || true

echo "[FULL] 5/5 冒烟验证并记录 TEST_REPORT"
for e in "${kind_selected[@]}" "${k3d_selected[@]}"; do
  "$ROOT_DIR/scripts/smoke.sh" "$e" || true
done

total_end=$(ts)
total_dur=$((total_end-total_start))
echo "[FULL] 完成"
echo "[TIME] 总耗时: $(fmtsec "$total_dur")"
echo "[TIME] 各环境创建耗时:"
for e in "${kind_selected[@]}" "${k3d_selected[@]}"; do
  dur="n/a"; [ -f "$ROOT_DIR/data/times/${e}.time" ] && dur=$(cat "$ROOT_DIR/data/times/${e}.time")
  printf '  - %s: %ss\n' "$e" "$dur"
done

# 附加 Portainer endpoints 列表与耗时汇总到报告
{
  echo "- phase(environments): done (concurrency=${concurrency})"
  echo "- phase(haproxy+smoke): done"
  echo "- total: ${total_dur}s"
  echo "- env durations:"
  for e in "${kind_selected[@]}" "${k3d_selected[@]}"; do
    dur="n/a"; [ -f "$ROOT_DIR/data/times/${e}.time" ] && dur=$(cat "$ROOT_DIR/data/times/${e}.time")
    echo "  - ${e}: ${dur}s"
  done
  echo "- portainer endpoints:"
  jwt=$("$ROOT_DIR/scripts/portainer.sh" api-login 2>/dev/null || true)
  base=$("$ROOT_DIR/scripts/portainer.sh" api-base 2>/dev/null || echo "")
  if [ -n "$jwt" ] && [ -n "$base" ]; then
    curl -sk -H "Authorization: Bearer $jwt" "$base/api/endpoints" | jq -r '.[] | "  - [\(.Id)] \(.Name) Type=\(.Type) Status=\(.Status) URL=\(.URL)"'
  else
    echo "  (unavailable)"
  fi
} >>"$report_file"
