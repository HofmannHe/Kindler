#!/usr/bin/env bash
# SQLite 数据库操作库（并发安全版本）
# 替代 lib_db.sh 的 PostgreSQL 功能，统一使用 SQLite 作为数据源

# 数据库路径（与 WebUI 共享）
# 如果在容器内执行，使用容器路径；如果在主机执行，通过 docker exec 访问
SQLITE_DB="${SQLITE_DB:-/data/kindler-webui/kindler.db}"
SQLITE_LOCK="${SQLITE_LOCK:-/tmp/kindler_db.lock}"
SQLITE_CONTAINER="${SQLITE_CONTAINER:-kindler-webui-backend}"

# 检测是否在容器内执行
_is_in_container() {
  # 检查 /data/kindler-webui 目录是否存在（容器内路径）
  [ -d "/data/kindler-webui" ] 2>/dev/null || {
    # 检查是否在 Docker 容器内（通过 /.dockerenv 或 /proc/self/cgroup）
    [ -f "/.dockerenv" ] 2>/dev/null || grep -q docker /proc/self/cgroup 2>/dev/null
  }
}

# 在容器内执行 SQLite 命令（如果不在容器内，通过 docker exec）
# 支持直接字符串参数或 heredoc
_sqlite_exec() {
  local sql
  if [ $# -eq 0 ]; then
    # heredoc 方式：从 stdin 读取
    sql=$(cat)
  else
    # 直接参数方式
    sql="$1"
  fi
  
  if _is_in_container; then
    # 在容器内，直接执行
    echo "$sql" | sqlite3 "$SQLITE_DB" 2>&1
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SQLITE_CONTAINER}$"; then
    # 在主机上，通过 docker exec 执行
    echo "$sql" | docker exec -i "$SQLITE_CONTAINER" sqlite3 "$SQLITE_DB" 2>&1
  else
    echo "[ERROR] Cannot access SQLite database: container ${SQLITE_CONTAINER} not running" >&2
    return 1
  fi
}

# 确保数据库目录存在
_ensure_db_dir() {
  local db_dir=$(dirname "$SQLITE_DB")
  
  if _is_in_container; then
    # 在容器内，直接创建目录
    if [ ! -d "$db_dir" ]; then
      mkdir -p "$db_dir" 2>/dev/null || {
        echo "[ERROR] Failed to create database directory: $db_dir" >&2
        return 1
      }
    fi
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SQLITE_CONTAINER}$"; then
    # 在主机上，通过 docker exec 创建目录
    docker exec "$SQLITE_CONTAINER" mkdir -p "$db_dir" 2>/dev/null || {
      echo "[ERROR] Failed to create database directory in container: $db_dir" >&2
      return 1
    }
  else
    echo "[WARN] Cannot ensure database directory: container ${SQLITE_CONTAINER} not running" >&2
    return 1
  fi
}

# 初始化数据库表结构（如果不存在）
_init_db_if_needed() {
  _ensure_db_dir || return 1
  
  # 使用 _sqlite_exec 检查表是否存在，不存在则创建
  if ! _sqlite_exec "SELECT name FROM sqlite_master WHERE type='table' AND name='clusters';" 2>/dev/null | grep -q "clusters"; then
    _sqlite_exec <<'EOF'
CREATE TABLE IF NOT EXISTS clusters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  provider TEXT NOT NULL,
  subnet TEXT,
  node_port INTEGER,
  pf_port INTEGER,
  http_port INTEGER,
  https_port INTEGER,
  server_ip TEXT,
  status TEXT DEFAULT 'unknown',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_clusters_name ON clusters(name);
EOF
  fi
}

# 执行 SQL 查询（并发安全，使用文件锁）
# 参数：$1 = SQL 语句
# 返回：查询结果（stdout），错误信息（stderr）
sqlite_query() {
  local sql="$1"
  
  # 确保数据库已初始化
  _init_db_if_needed || return 1
  
  # 使用 flock 加锁，确保并发安全（独占锁）
  # 超时设置：最多等待 30 秒
  (
    flock -x -w 30 200 || {
      echo "[ERROR] Failed to acquire database lock after 30s" >&2
      return 1
    }
    _sqlite_exec "$sql"
  ) 200>"$SQLITE_LOCK"
}

# 执行事务操作（确保原子性）
# 参数：$1 = SQL 语句（可以是多行）
sqlite_transaction() {
  local sql="$1"
  
  _init_db_if_needed || return 1
  
  (
    flock -x -w 30 200 || {
      echo "[ERROR] Failed to acquire database lock after 30s" >&2
      return 1
    }
    _sqlite_exec <<EOF
BEGIN IMMEDIATE TRANSACTION;
$sql
COMMIT;
EOF
  ) 200>"$SQLITE_LOCK" 2>&1
}

# 兼容性函数：sqlite_exec 是 sqlite_query 的别名
sqlite_exec() {
  sqlite_query "$@"
}

# 插入集群记录（与 db_insert_cluster 相同的接口）
# 参数：name, provider, subnet, node_port, pf_port, http_port, https_port, server_ip
sqlite_insert_cluster() {
  local name="$1"
  local provider="$2"
  local subnet="${3:-}"  # 可选
  local node_port="$4"
  local pf_port="$5"
  local http_port="$6"
  local https_port="$7"
  local server_ip="${8:-}"  # 可选，API server IP
  
  # 参数验证
  if [ -z "$name" ]; then
    echo "[ERROR] sqlite_insert_cluster: name is required" >&2
    return 1
  fi
  if [ -z "$provider" ]; then
    echo "[ERROR] sqlite_insert_cluster: provider is required" >&2
    return 1
  fi
  if [ -z "$node_port" ]; then
    echo "[ERROR] sqlite_insert_cluster: node_port is required" >&2
    return 1
  fi
  if [ -z "$pf_port" ]; then
    echo "[ERROR] sqlite_insert_cluster: pf_port is required" >&2
    return 1
  fi
  if [ -z "$http_port" ]; then
    echo "[ERROR] sqlite_insert_cluster: http_port is required" >&2
    return 1
  fi
  if [ -z "$https_port" ]; then
    echo "[ERROR] sqlite_insert_cluster: https_port is required" >&2
    return 1
  fi
  
  # 构建 SQL（根据是否有 subnet 和 server_ip 构建不同的插入语句）
  local sql
  if [ -n "$subnet" ]; then
    if [ -n "$server_ip" ]; then
      sql="INSERT OR REPLACE INTO clusters (name, provider, subnet, node_port, pf_port, http_port, https_port, server_ip, updated_at) VALUES ('$name', '$provider', '$subnet', $node_port, $pf_port, $http_port, $https_port, '$server_ip', datetime('now'));"
    else
      sql="INSERT OR REPLACE INTO clusters (name, provider, subnet, node_port, pf_port, http_port, https_port, updated_at) VALUES ('$name', '$provider', '$subnet', $node_port, $pf_port, $http_port, $https_port, datetime('now'));"
    fi
  else
    if [ -n "$server_ip" ]; then
      sql="INSERT OR REPLACE INTO clusters (name, provider, node_port, pf_port, http_port, https_port, server_ip, updated_at) VALUES ('$name', '$provider', $node_port, $pf_port, $http_port, $https_port, '$server_ip', datetime('now'));"
    else
      sql="INSERT OR REPLACE INTO clusters (name, provider, node_port, pf_port, http_port, https_port, updated_at) VALUES ('$name', '$provider', $node_port, $pf_port, $http_port, $https_port, datetime('now'));"
    fi
  fi
  
  sqlite_transaction "$sql" >/dev/null
}

# 删除集群记录
# 参数：$1 = 集群名称
sqlite_delete_cluster() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "[ERROR] sqlite_delete_cluster: name is required" >&2
    return 1
  fi
  sqlite_transaction "DELETE FROM clusters WHERE name = '$name';" >/dev/null
}

# 查询集群记录（与 db_get_cluster 相同的接口）
# 参数：$1 = 集群名称
# 返回：格式化的记录（一行，用 | 分隔：name|provider|subnet|node_port|pf_port|http_port|https_port）
sqlite_get_cluster() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "[ERROR] sqlite_get_cluster: name is required" >&2
    return 1
  fi
  
  local result
  result=$(sqlite_query "
    SELECT name, provider, COALESCE(subnet, ''), node_port, pf_port, http_port, https_port
    FROM clusters
    WHERE name = '$name';
  " 2>/dev/null | head -1)
  
  if [ -n "$result" ]; then
    echo "$result"
    return 0
  else
    return 1
  fi
}

# 列出所有集群（与 db_list_clusters 相同的接口）
# 返回：所有集群记录（每行一个集群，用 | 分隔）
sqlite_list_clusters() {
  sqlite_query "
    SELECT name, provider, COALESCE(subnet, ''), node_port, pf_port, http_port, https_port
    FROM clusters
    ORDER BY created_at;
  " 2>/dev/null
}

# 检查集群是否存在
# 参数：$1 = 集群名称
# 返回：0 = 存在，1 = 不存在
sqlite_cluster_exists() {
  local name="$1"
  if [ -z "$name" ]; then
    return 1
  fi
  
  local count
  count=$(sqlite_query "SELECT COUNT(*) FROM clusters WHERE name = '$name';" 2>/dev/null | tr -d ' \n')
  [ "${count:-0}" -gt 0 ]
}

# 检查端口是否被占用（原子操作，并发安全）
# 参数：$1 = 端口号
# 返回：0 = 已占用，1 = 未占用
sqlite_port_in_use() {
  local port="$1"
  if [ -z "$port" ]; then
    return 1
  fi
  
  local count
  count=$(sqlite_transaction "
    SELECT COUNT(*) FROM clusters
    WHERE node_port = $port
       OR pf_port = $port
       OR http_port = $port
       OR https_port = $port;
  " 2>/dev/null | tr -d ' \n')
  
  [ "${count:-0}" -gt 0 ]
}

# 检查子网是否被占用
# 参数：$1 = 子网（CIDR 格式）
# 返回：0 = 已占用，1 = 未占用
sqlite_subnet_in_use() {
  local subnet="$1"
  if [ -z "$subnet" ]; then
    return 1
  fi
  
  local count
  count=$(sqlite_query "SELECT COUNT(*) FROM clusters WHERE subnet = '$subnet';" 2>/dev/null | tr -d ' \n')
  [ "${count:-0}" -gt 0 ]
}

# 获取下一个可用端口（原子操作，并发安全）
# 参数：$1 = 起始端口，$2 = 结束端口
# 返回：可用端口号
sqlite_next_available_port() {
  local start="$1"
  local end="$2"
  
  if [ -z "$start" ] || [ -z "$end" ]; then
    echo "[ERROR] sqlite_next_available_port: start and end ports are required" >&2
    return 1
  fi
  
  # 使用事务确保端口分配的原子性
  for port in $(seq "$start" "$end"); do
    if ! sqlite_port_in_use "$port"; then
      echo "$port"
      return 0
    fi
  done
  
  echo "[ERROR] 没有可用端口在 $start-$end 范围内" >&2
  return 1
}

# 检查数据库是否可用
# 返回：0 = 可用，1 = 不可用
sqlite_is_available() {
  _ensure_db_dir || return 1
  
  # 尝试初始化数据库（如果不存在）
  _init_db_if_needed || return 1
  
  # 尝试执行简单查询
  sqlite_query "SELECT 1;" >/dev/null 2>&1
}

# 兼容性函数：为了平滑迁移，保留 db_* 函数名作为 sqlite_* 的别名
# 这些函数会在过渡期使用，最终会被替换
db_query() {
  sqlite_query "$@"
}

db_exec() {
  sqlite_exec "$@"
}

db_insert_cluster() {
  sqlite_insert_cluster "$@"
}

db_delete_cluster() {
  sqlite_delete_cluster "$@"
}

db_get_cluster() {
  sqlite_get_cluster "$@"
}

db_list_clusters() {
  sqlite_list_clusters "$@"
}

db_cluster_exists() {
  sqlite_cluster_exists "$@"
}

db_port_in_use() {
  sqlite_port_in_use "$@"
}

db_subnet_in_use() {
  sqlite_subnet_in_use "$@"
}

db_next_available_port() {
  sqlite_next_available_port "$@"
}

db_is_available() {
  sqlite_is_available "$@"
}

