#!/usr/bin/env bash
# 初始化 PostgreSQL 数据库表结构

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo "  初始化数据库表结构"
echo "=========================================="
echo ""

CTX="k3d-devops"
NAMESPACE="paas"
POD="postgresql-0"

echo "[DB] 等待 PostgreSQL 就绪..."
kubectl --context "$CTX" wait --for=condition=ready pod "$POD" -n "$NAMESPACE" --timeout=60s || {
  echo "[ERROR] PostgreSQL Pod 未就绪"
  exit 1
}

echo ""
echo "[DB] 创建 clusters 表..."
kubectl --context "$CTX" exec -i "$POD" -n "$NAMESPACE" -- psql -U kindler -d kindler <<'EOF'
-- 创建 clusters 表（包含 server_ip 列）
CREATE TABLE IF NOT EXISTS clusters (
  name VARCHAR(63) PRIMARY KEY,
  provider VARCHAR(10) NOT NULL CHECK (provider IN ('k3d', 'kind')),
  subnet CIDR,
  node_port INT NOT NULL,
  pf_port INT NOT NULL,
  http_port INT NOT NULL,
  https_port INT NOT NULL,
  server_ip VARCHAR(45),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_clusters_provider ON clusters(provider);
CREATE INDEX IF NOT EXISTS idx_clusters_created_at ON clusters(created_at);

-- 创建任务表（用于任务持久化）
CREATE TABLE IF NOT EXISTS tasks (
  task_id VARCHAR(64) PRIMARY KEY,
  status VARCHAR(20) NOT NULL,
  progress INT DEFAULT 0,
  message TEXT,
  logs TEXT,
  error TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 创建任务索引
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at);

EOF

echo ""
echo "[DB] 验证 server_ip 列存在..."
if ! kubectl --context "$CTX" exec -i "$POD" -n "$NAMESPACE" -- \
  psql -U kindler -d kindler -c "\d clusters" | grep -q "server_ip"; then
  echo "[ERROR] server_ip column not found in clusters table!"
  echo "[FIX] Check CREATE TABLE statement in this script"
  exit 1
fi
echo "✓ server_ip column exists"

echo ""
echo "[DB] 验证表结构..."
kubectl --context "$CTX" exec -i "$POD" -n "$NAMESPACE" -- psql -U kindler -d kindler -c '\d clusters' | head -20

echo ""
echo "=========================================="
echo "✅ 数据库初始化完成！"
echo "=========================================="
echo ""
echo "验证："
echo "  kubectl --context $CTX exec -i $POD -n $NAMESPACE -- psql -U kindler -d kindler -c 'SELECT * FROM clusters;'"
echo ""


