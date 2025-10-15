#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
PROJECTS_CSV="$ROOT_DIR/config/projects.csv"

usage() {
  cat >&2 <<USAGE
Usage: $0 {add|remove} <project-name> --env <env> [--node-port <port>]

说明：
- 为项目添加/移除 HAProxy 路由
- 支持项目级域名: <service>.<project>.<env>.<BASE_DOMAIN>
- 例如: whoami.project-a.dev.192.168.51.30.sslip.io

Options:
  --env <env>        环境名称 (dev/uat/prod)
  --node-port <port> 节点端口 (默认: 30080)
USAGE
  exit 1
}

# 解析项目配置
parse_projects_csv() {
  [ -f "$PROJECTS_CSV" ] || return 1
  awk -F, '$0 !~ /^[[:space:]]*#/ && NF>0 {print $0}' "$PROJECTS_CSV" | tr -d '\r'
}

# 查找项目配置
find_project() {
  local project="$1" env="$2"
  parse_projects_csv | awk -F, -v p="$project" -v e="$env" '$1==p && $2==e {print; exit}'
}

# 获取集群 IP
get_cluster_ip() {
  local env="$1"
  local provider=$(provider_for "$env")
  
  if [ "$provider" = "k3d" ]; then
    docker inspect "k3d-${env}-server-0" --format '{{with index .NetworkSettings.Networks "k3d-shared"}}{{.IPAddress}}{{end}}' 2>/dev/null || \
    docker inspect "k3d-${env}-server-0" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || \
    echo "127.0.0.1"
  else
    docker inspect "${env}-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || \
    echo "127.0.0.1"
  fi
}

# 添加项目路由
add_project_route() {
  local project="$1" env="$2" node_port="$3"
  
  echo "[HAPROXY] 添加项目路由: $project (环境: $env)"
  
  # 检查项目是否存在
  if ! project_config=$(find_project "$project" "$env"); then
    echo "错误: 项目 '$project' 在环境 '$env' 中不存在" >&2
    exit 1
  fi
  
  IFS=, read -r p_name p_env p_namespace p_team p_cpu p_memory p_domain p_created p_desc <<<"$project_config"
  
  # 获取集群 IP
  local cluster_ip=$(get_cluster_ip "$env")
  
  # 生成项目级域名模式
  local project_pattern="<service>\\.${project}\\.${env}\\.[^:]+"
  local acl_name="host_${project}_${env}"
  local backend_name="be_${project}_${env}"
  
  # 添加 ACL 规则
  local acl_line="acl ${acl_name} hdr_reg(host) -i ^[^.]+\\.${project}\\.${env}\\.[^:]+"
  local use_backend_line="use_backend ${backend_name} if ${acl_name}"
  
  # 检查是否已存在
  if grep -q "acl ${acl_name}" "$CFG"; then
    echo "[HAPROXY] 路由已存在，跳过"
    return 0
  fi
  
  # 在 DYNAMIC ACL 区域添加 ACL
  local tmp_file=$(mktemp)
  awk -v acl="$acl_line" -v backend="$use_backend_line" '
    /^# BEGIN DYNAMIC ACL/ { print; print "  " acl; print "  " backend; next }
    { print }
  ' "$CFG" > "$tmp_file"
  mv "$tmp_file" "$CFG"
  
  # 添加 backend
  local backend_section="backend ${backend_name}\n  server s1 ${cluster_ip}:${node_port}"
  
  # 在 DYNAMIC BACKENDS 区域添加 backend
  local tmp_file=$(mktemp)
  awk -v backend="$backend_section" '
    /^# BEGIN DYNAMIC BACKENDS/ { print; print backend; next }
    { print }
  ' "$CFG" > "$tmp_file"
  mv "$tmp_file" "$CFG"
  
  # 重载 HAProxy
  if [ "${NO_RELOAD:-}" != "1" ]; then
    echo "[HAPROXY] 重载配置..."
    docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" restart haproxy >/dev/null 2>&1 || \
      docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d haproxy >/dev/null
  fi
  
  echo "[HAPROXY] 项目路由添加成功"
  echo "  - 项目: $project"
  echo "  - 环境: $env"
  echo "  - 域名模式: <service>.${project}.${env}.${BASE_DOMAIN}"
  echo "  - 后端: ${cluster_ip}:${node_port}"
}

# 移除项目路由
remove_project_route() {
  local project="$1" env="$2"
  
  echo "[HAPROXY] 移除项目路由: $project (环境: $env)"
  
  local acl_name="host_${project}_${env}"
  local backend_name="be_${project}_${env}"
  
  # 移除 ACL 和 backend
  local tmp_file=$(mktemp)
  awk -v acl="$acl_name" -v backend="$backend_name" '
    /^[[:space:]]*acl[[:space:]]+host_/ && $0 ~ acl { next }
    /^[[:space:]]*use_backend[[:space:]]+be_/ && $0 ~ backend { next }
    /^backend[[:space:]]+be_/ && $0 ~ backend { skip=1; next }
    skip && /^[[:space:]]*server/ { next }
    skip && /^$/ { skip=0; next }
    { print }
  ' "$CFG" > "$tmp_file"
  mv "$tmp_file" "$CFG"
  
  # 重载 HAProxy
  if [ "${NO_RELOAD:-}" != "1" ]; then
    echo "[HAPROXY] 重载配置..."
    docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" restart haproxy >/dev/null 2>&1 || \
      docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d haproxy >/dev/null
  fi
  
  echo "[HAPROXY] 项目路由移除成功"
}

# 主函数
main() {
  local command="$1"
  local project="$2"
  shift 2
  
  local env="" node_port="30080"
  
  # 解析参数
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) env="$2"; shift 2 ;;
      --node-port) node_port="$2"; shift 2 ;;
      *) echo "未知选项: $1" >&2; usage ;;
    esac
  done
  
  [ -n "$env" ] || {
    echo "错误: 必须指定 --env 参数" >&2
    usage
  }
  
  case "$command" in
    add)
      add_project_route "$project" "$env" "$node_port"
      ;;
    remove)
      remove_project_route "$project" "$env"
      ;;
    *)
      echo "未知命令: $command" >&2
      usage
      ;;
  esac
}

[ $# -lt 3 ] && usage
main "$@"
