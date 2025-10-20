#!/usr/bin/env bash
# CSV 配置迁移到数据库（一次性工具）

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib_db.sh"

CSV_FILE="$ROOT_DIR/config/environments.csv"

echo "=========================================="
echo "  CSV 配置迁移到数据库"
echo "=========================================="
echo ""

# 检查数据库是否可用
if ! db_is_available 2>/dev/null; then
  echo "[ERROR] 数据库不可用，无法迁移"
  echo "请确保："
  echo "  1. devops 集群正在运行"
  echo "  2. PostgreSQL Pod 已就绪"
  echo ""
  echo "验证命令："
  echo "  kubectl --context k3d-devops get pods -n paas"
  exit 1
fi

# 检查 CSV 文件是否存在
if [ ! -f "$CSV_FILE" ]; then
  echo "[ERROR] CSV 文件不存在: $CSV_FILE"
  exit 1
fi

echo "[INFO] 读取 CSV 配置..."
echo ""

# 统计
total=0
success=0
skipped=0
failed=0

# 读取 CSV 文件（跳过注释、空行和标题行）
while IFS=, read -r env provider node_port pf_port reg_portainer haproxy_route http_port https_port subnet; do
  # 跳过 devops 集群（管理集群不需要迁移）
  if [ "$env" = "devops" ]; then
    echo "[SKIP] devops (management cluster, not migrating)"
    skipped=$((skipped + 1))
    continue
  fi
  
  # 清理空格
  env=$(echo "$env" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  provider=$(echo "$provider" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  subnet=$(echo "$subnet" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  node_port=$(echo "$node_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  pf_port=$(echo "$pf_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  http_port=$(echo "$http_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  https_port=$(echo "$https_port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  total=$((total + 1))
  
  # 检查是否已存在
  if db_cluster_exists "$env" 2>/dev/null; then
    echo "[SKIP] $env (already in database)"
    skipped=$((skipped + 1))
    continue
  fi
  
  # 插入到数据库
  echo "[MIGRATE] $env (provider: $provider, subnet: ${subnet:-none})"
  if db_insert_cluster "$env" "$provider" "${subnet:-}" "$node_port" "$pf_port" "$http_port" "$https_port" 2>/dev/null; then
    echo "[SUCCESS] ✓ $env migrated"
    success=$((success + 1))
  else
    echo "[ERROR] ✗ $env migration failed"
    failed=$((failed + 1))
  fi
  echo ""
done < <(awk -F, 'NR > 1 && $0 !~ /^[[:space:]]*#/ && NF > 0' "$CSV_FILE")

echo "=========================================="
echo "  迁移完成"
echo "=========================================="
echo ""
echo "统计："
echo "  总计: $total"
echo "  成功: $success"
echo "  跳过: $skipped"
echo "  失败: $failed"
echo ""

if [ $failed -gt 0 ]; then
  echo "[WARN] 部分环境迁移失败"
  exit 1
fi

echo "验证："
echo "  scripts/list_env.sh"
echo ""


