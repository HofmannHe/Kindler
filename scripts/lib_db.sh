#!/usr/bin/env bash
# 数据库操作库（极简版）

# 数据库连接参数
DB_CTX="${DB_CTX:-k3d-devops}"
DB_NAMESPACE="${DB_NAMESPACE:-paas}"
DB_POD="${DB_POD:-postgresql-0}"
DB_USER="${DB_USER:-kindler}"
DB_NAME="${DB_NAME:-kindler}"

# 执行 SQL 查询
# 参数：$1 = SQL 语句
# 返回：查询结果（stdout），错误信息（stderr）
db_query() {
  local sql="$1"
  kubectl --context "$DB_CTX" exec -i "$DB_POD" -n "$DB_NAMESPACE" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$sql"
}

# db_exec 是 db_query 的别名（兼容性）
db_exec() {
  db_query "$@"
}

# 插入集群记录
# 参数：name, provider, subnet, node_port, pf_port, http_port, https_port
db_insert_cluster() {
  local name="$1"
  local provider="$2"
  local subnet="${3:-}"  # 可选
  local node_port="$4"
  local pf_port="$5"
  local http_port="$6"
  local https_port="$7"
  
  if [ -n "$subnet" ]; then
    # 包含 subnet
    db_query "
      INSERT INTO clusters (name, provider, subnet, node_port, pf_port, http_port, https_port)
      VALUES ('$name', '$provider', '$subnet'::CIDR, $node_port, $pf_port, $http_port, $https_port)
      ON CONFLICT (name) DO UPDATE SET
        provider = EXCLUDED.provider,
        subnet = EXCLUDED.subnet,
        node_port = EXCLUDED.node_port,
        pf_port = EXCLUDED.pf_port,
        http_port = EXCLUDED.http_port,
        https_port = EXCLUDED.https_port,
        updated_at = CURRENT_TIMESTAMP;
    " >/dev/null
  else
    # 不包含 subnet (kind 集群)
    db_query "
      INSERT INTO clusters (name, provider, node_port, pf_port, http_port, https_port)
      VALUES ('$name', '$provider', $node_port, $pf_port, $http_port, $https_port)
      ON CONFLICT (name) DO UPDATE SET
        provider = EXCLUDED.provider,
        node_port = EXCLUDED.node_port,
        pf_port = EXCLUDED.pf_port,
        http_port = EXCLUDED.http_port,
        https_port = EXCLUDED.https_port,
        updated_at = CURRENT_TIMESTAMP;
    " >/dev/null
  fi
}

# 删除集群记录
# 参数：$1 = 集群名称
db_delete_cluster() {
  local name="$1"
  db_query "DELETE FROM clusters WHERE name = '$name';" >/dev/null
}

# 查询集群记录
# 参数：$1 = 集群名称
# 返回：格式化的记录（一行，用 | 分隔）
db_get_cluster() {
  local name="$1"
  db_query "
    SELECT name, provider, subnet, node_port, pf_port, http_port, https_port
    FROM clusters
    WHERE name = '$name';
  "
}

# 列出所有集群
# 返回：所有集群记录（每行一个集群，用 | 分隔）
db_list_clusters() {
  db_query "
    SELECT name, provider, subnet, node_port, pf_port, http_port, https_port
    FROM clusters
    ORDER BY created_at;
  "
}

# 检查集群是否存在
# 参数：$1 = 集群名称
# 返回：0 = 存在，1 = 不存在
db_cluster_exists() {
  local name="$1"
  local count
  count=$(db_query "SELECT COUNT(*) FROM clusters WHERE name = '$name';")
  [ "$count" -gt 0 ]
}

# 检查端口是否被占用
# 参数：$1 = 端口号
# 返回：0 = 已占用，1 = 未占用
db_port_in_use() {
  local port="$1"
  local count
  count=$(db_query "
    SELECT COUNT(*) FROM clusters
    WHERE node_port = $port
       OR pf_port = $port
       OR http_port = $port
       OR https_port = $port;
  ")
  [ "$count" -gt 0 ]
}

# 检查子网是否被占用
# 参数：$1 = 子网（CIDR 格式）
# 返回：0 = 已占用，1 = 未占用
db_subnet_in_use() {
  local subnet="$1"
  local count
  count=$(db_query "SELECT COUNT(*) FROM clusters WHERE subnet = '$subnet'::CIDR;")
  [ "$count" -gt 0 ]
}

# 获取下一个可用端口
# 参数：$1 = 起始端口，$2 = 结束端口
# 返回：可用端口号
db_next_available_port() {
  local start="$1"
  local end="$2"
  
  for port in $(seq "$start" "$end"); do
    if ! db_port_in_use "$port"; then
      echo "$port"
      return 0
    fi
  done
  
  echo "[ERROR] 没有可用端口在 $start-$end 范围内" >&2
  return 1
}

# 检查数据库是否可用
# 返回：0 = 可用，1 = 不可用
db_is_available() {
  db_query "SELECT 1;" >/dev/null 2>&1
}


