#!/usr/bin/env bash
# 列出所有环境配置（优先从数据库读取，回退到 CSV）

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib_db.sh"

echo "=========================================="
echo "  环境列表"
echo "=========================================="
echo ""

# 尝试从数据库读取
if db_is_available 2>/dev/null; then
  echo "[INFO] 数据来源: PostgreSQL 数据库"
  echo ""
  
  # 查询所有集群
  clusters=$(db_list_clusters 2>/dev/null || echo "")
  
  if [ -z "$clusters" ]; then
    echo "[WARN] 数据库中没有集群记录"
  else
    # 打印表头
    printf "%-15s %-10s %-18s %-10s %-8s %-10s %-11s\n" \
      "NAME" "PROVIDER" "SUBNET" "NODE_PORT" "PF_PORT" "HTTP_PORT" "HTTPS_PORT"
    echo "---------------------------------------------------------------------------------------------"
    
    # 打印每个集群
    while IFS='|' read -r name provider subnet node_port pf_port http_port https_port; do
      # 如果子网为空，显示 N/A
      [ -z "$subnet" ] && subnet="N/A"
      
      printf "%-15s %-10s %-18s %-10s %-8s %-10s %-11s\n" \
        "$name" "$provider" "$subnet" "$node_port" "$pf_port" "$http_port" "$https_port"
    done <<< "$clusters"
  fi
else
  echo "[INFO] 数据来源: config/environments.csv (数据库不可用)"
  echo ""
  
  CSV_FILE="$ROOT_DIR/config/environments.csv"
  if [ ! -f "$CSV_FILE" ]; then
    echo "[ERROR] CSV 文件不存在: $CSV_FILE"
    exit 1
  fi
  
  # 打印表头
  printf "%-15s %-10s %-18s %-10s %-8s %-10s %-11s\n" \
    "NAME" "PROVIDER" "SUBNET" "NODE_PORT" "PF_PORT" "HTTP_PORT" "HTTPS_PORT"
  echo "---------------------------------------------------------------------------------------------"
  
  # 读取 CSV 文件（跳过注释和空行，跳过第一行标题）
  awk -F, '
    NR > 1 && 
    $0 !~ /^[[:space:]]*#/ && 
    NF > 0 {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $9)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $7)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $8)
      
      subnet = ($9 == "" || $9 == "N/A") ? "N/A" : $9
      
      printf "%-15s %-10s %-18s %-10s %-8s %-10s %-11s\n", 
        $1, $2, subnet, $3, $4, $7, $8
    }
  ' "$CSV_FILE"
fi

echo ""
echo "=========================================="
echo "提示："
echo "  - 使用 'scripts/create_env.sh -n <name>' 创建新环境"
echo "  - 使用 'scripts/delete_env.sh -n <name>' 删除环境"
echo ""


