#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"

# 加载配置
if [ -f "$ROOT_DIR/config/clusters.env" ]; then
	. "$ROOT_DIR/config/clusters.env"
fi

usage() {
	cat >&2 <<EOF
Usage: $0 [--max-parallel <N>] [--include-devops]

批量并行创建所有业务集群（从 config/environments.csv 读取）

选项:
  --max-parallel <N>   最大并行任务数（默认：6）
  --include-devops     包含 devops 集群（默认排除）
  -h, --help           显示帮助信息
EOF
	exit 1
}

# 参数解析
MAX_PARALLEL=6
INCLUDE_DEVOPS=0

while [[ $# -gt 0 ]]; do
	case $1 in
	--max-parallel)
		MAX_PARALLEL="$2"
		shift 2
		;;
	--include-devops)
		INCLUDE_DEVOPS=1
		shift
		;;
	-h | --help)
		usage
		;;
	*)
		echo "Unknown option: $1" >&2
		usage
		;;
	esac
done

CSV="$ROOT_DIR/config/environments.csv"
if [ ! -f "$CSV" ]; then
	echo "[ERROR] Configuration file not found: $CSV" >&2
	exit 1
fi

# 创建日志目录
LOG_DIR="$ROOT_DIR/data/logs"
mkdir -p "$LOG_DIR"

echo "[BATCH] Starting parallel cluster creation (max $MAX_PARALLEL concurrent jobs)..."
echo "[BATCH] Logs will be stored in: $LOG_DIR"

# Avoid per-cluster HAProxy reloads during parallel creation; we will sync once at the end
export NO_RELOAD=1

# 读取环境列表并启动并行创建
pids=()
envs=()
start_time=$(date +%s)

while IFS=, read -r env provider node_port pf_port register_portainer haproxy_route http_port https_port cluster_subnet; do
	# 跳过注释和空行
	[[ "$env" =~ ^[[:space:]]*# ]] && continue
	[ -z "$env" ] && continue

	# 跳过 devops（除非明确包含）
	if [ "$INCLUDE_DEVOPS" = "0" ] && [ "$env" = "devops" ]; then
		continue
	fi

	# 默认 provider 为 kind
	provider="${provider:-kind}"
	provider=$(echo "$provider" | sed -e 's/^\s\+//' -e 's/\s\+$//')

	envs+=("$env")
	log_file="$LOG_DIR/create_${env}.log"

	echo "[BATCH] Starting creation: $env (provider: $provider)"

	# 并行创建（后台任务）
	(
		if "$ROOT_DIR/scripts/create_env.sh" -n "$env" -p "$provider" >"$log_file" 2>&1; then
			echo "✓ $env" >>"$LOG_DIR/summary.log"
			echo "[BATCH] ✓ $env completed successfully"
		else
			echo "✗ $env" >>"$LOG_DIR/summary.log"
			echo "[BATCH] ✗ $env failed (see $log_file)"
		fi
	) &

	pids+=($!)

	# 限制并发数
	if [ ${#pids[@]} -ge $MAX_PARALLEL ]; then
		# 等待任意一个完成
		wait -n "${pids[@]}" 2>/dev/null || true
		# 清理已完成的 pid
		new_pids=()
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				new_pids+=("$pid")
			fi
		done
		pids=("${new_pids[@]}")
	fi
done < <(tail -n +2 "$CSV")

# 等待所有任务完成
echo "[BATCH] Waiting for all tasks to complete..."
for pid in "${pids[@]}"; do
	wait "$pid" 2>/dev/null || true
done

end_time=$(date +%s)
duration=$((end_time - start_time))

# 汇总结果
echo ""
echo "=================================================="
echo "[BATCH] Summary"
echo "=================================================="
echo "Total environments: ${#envs[@]}"
echo "Duration: ${duration}s"
echo ""

if [ -f "$LOG_DIR/summary.log" ]; then
	success=$(grep -c '^✓' "$LOG_DIR/summary.log" || true)
	failed=$(grep -c '^✗' "$LOG_DIR/summary.log" || true)
	echo "Success: $success"
	echo "Failed:  $failed"
	echo ""

    if [ "$failed" -gt 0 ]; then
        echo "Failed environments:"
        grep '^✗' "$LOG_DIR/summary.log" | sed 's/^/  /'
        echo ""
        echo "Check logs in $LOG_DIR for details"
        exit 1
    else
        echo "All environments created successfully! ✓"
        # 单次同步 HAProxy 动态路由并执行一次重载
        echo "[BATCH] Syncing HAProxy routes from DB and pruning stale entries..."
        "$ROOT_DIR/scripts/haproxy_sync.sh" --prune || true
        rm -f "$LOG_DIR/summary.log"
        exit 0
    fi
else
	echo "No environments were created"
	exit 0
fi
