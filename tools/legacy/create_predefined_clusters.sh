#!/usr/bin/env bash
# 创建预置集群（dev, uat, prod）
# 从 environments.csv 读取配置并批量创建
# DEPRECATED: prefer tools/maintenance/batch_create_envs.sh for parallel creation from CSV.

set -Eeuo pipefail
IFS=$'\n\t'

echo "[DEPRECATED] create_predefined_clusters.sh 已弃用，请使用 tools/maintenance/batch_create_envs.sh --from-csv。" >&2

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

echo "=========================================="
echo "  创建预置业务集群"
echo "=========================================="
echo ""

CSV_FILE="$ROOT_DIR/config/environments.csv"
if [ ! -f "$CSV_FILE" ]; then
  echo "[ERROR] CSV file not found: $CSV_FILE"
  exit 1
fi

# 读取预置集群（排除 devops 和 test- 开头的）
echo "[1/3] 读取预置集群配置..."
predefined_clusters=$(awk -F, '$0 !~ /^[[:space:]]*#/ && NF>0 && $1!="devops" && $1 !~ /^test-/ {print $1","$2}' "$CSV_FILE" || echo "")

if [ -z "$predefined_clusters" ]; then
  echo "  ⚠ 没有找到预置集群配置"
  exit 0
fi

echo "  预置集群:"
echo "$predefined_clusters" | sed 's/^/    /'
echo ""

# 并行创建集群
echo "[2/3] 创建预置集群..."
pids=()
failed_clusters=()
success_clusters=()

while IFS=',' read -r name provider; do
  [ -z "$name" ] && continue
  
  # 检查集群是否已存在
  ctx=""
  if [ "$provider" = "k3d" ]; then
    ctx="k3d-${name}"
  else
    ctx="kind-${name}"
  fi
  
  if kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
    echo "  ✓ $name 已存在，跳过"
    success_clusters+=("$name")
    continue
  fi
  
  echo "  创建 $name ($provider)..."
  
  # 并行创建
  (
    if "$ROOT_DIR/scripts/create_env.sh" -n "$name" -p "$provider" >/tmp/create_${name}.log 2>&1; then
      echo "    ✓ $name 创建成功" >> /tmp/predefined_summary.log
    else
      echo "    ✗ $name 创建失败" >> /tmp/predefined_summary.log
    fi
  ) &
  
  pids+=($!)
  
  # 限制并发数为 3
  if [ ${#pids[@]} -ge 3 ]; then
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
done < <(echo "$predefined_clusters")

# 等待所有创建完成
echo "  等待所有创建任务完成..."
for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

echo ""

# 汇总结果
echo "[3/3] 汇总创建结果..."
if [ -f /tmp/predefined_summary.log ]; then
  success=$(grep -c '✓' /tmp/predefined_summary.log 2>/dev/null || echo "0")
  failed=$(grep -c '✗' /tmp/predefined_summary.log 2>/dev/null || echo "0")
  
  echo "  成功: $success"
  echo "  失败: $failed"
  
  if [ "$failed" -gt 0 ]; then
    echo ""
    echo "  失败的集群:"
    grep '✗' /tmp/predefined_summary.log | sed 's/^/  /'
    echo ""
    echo "  查看日志: /tmp/create_*.log"
    
    rm -f /tmp/predefined_summary.log
    exit 1
  fi
  
  rm -f /tmp/predefined_summary.log
else
  echo "  ⚠ 未生成汇总日志"
fi

echo ""
echo "=========================================="
echo "✅ 预置集群创建完成"
echo "=========================================="
echo ""
echo "验证:"
echo "  scripts/cluster.sh list"
echo "  kubectl config get-contexts | grep -E 'dev|uat|prod'"
