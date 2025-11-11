#!/usr/bin/env bash
# Moved from scripts/project_manage.sh
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"

usage() {
  cat >&2 <<USAGE
Usage: $0 <command> [options]

Commands:
  list [--env <env>]                    # 列出所有项目或指定环境的项目
  create --project <name> --env <env> [options]  # 创建项目
  show --project <name> [--env <env>]   # 查看项目详情
  update --project <name> [options]     # 更新项目配置
  delete --project <name> [--env <env>] # 删除项目
  kubeconfig --project <name> --env <env> [--output <file>] # 生成项目 kubeconfig

Options:
  --project <name>       项目名称
  --env <env>            环境名称 (dev/uat/prod)
  --team <team>          团队名称
  --cpu-limit <limit>    CPU 限制 (如: 2)
  --memory-limit <limit> 内存限制 (如: 4Gi)
  --description <desc>   项目描述
  --output <file>        kubeconfig 输出文件路径

Examples:
  $0 list
  $0 list --env dev
  $0 create --project project-a --env dev --team frontend --cpu-limit 2 --memory-limit 4Gi
  $0 show --project project-a --env dev
  $0 update --project project-a --cpu-limit 4
  $0 delete --project project-a --env dev
  $0 kubeconfig --project project-a --env dev --output ~/.kube/project-a-dev.yaml
USAGE
  exit 1
}

# 加载配置
load_env
PROJECTS_CSV="$ROOT_DIR/config/projects.csv"

# 解析 CSV 中的项目配置
parse_projects_csv() {
  [ -f "$PROJECTS_CSV" ] || return 1
  awk -F, '$0 !~ /^[[:space:]]*#/ && NF>0 {print $0}' "$PROJECTS_CSV" | tr -d '\r'
}

# 查找项目配置
find_project() {
  local project="$1" env="$2"
  parse_projects_csv | awk -F, -v p="$project" -v e="$env" '$1==p && $2==e {print; exit}'
}

# 列出项目
list_projects() {
  local env_filter="$1"
  echo "项目列表:"
  echo "项目名称 | 环境 | 命名空间 | 团队 | CPU限制 | 内存限制 | 创建时间"
  echo "--------|------|----------|------|--------|----------|----------"
  
  if [ -n "$env_filter" ]; then
    parse_projects_csv | awk -F, -v e="$env_filter" '$2==e {
      printf "%-10s | %-4s | %-8s | %-6s | %-6s | %-8s | %-10s\n", 
        $1, $2, $3, $4, $5, $6, $8
    }'
  else
    parse_projects_csv | awk -F, '{
      printf "%-10s | %-4s | %-8s | %-6s | %-6s | %-8s | %-10s\n", 
        $1, $2, $3, $4, $5, $6, $8
    }'
  fi
}

# 创建项目
create_project() {
  local project="$1" env="$2" team="$3" cpu_limit="$4" memory_limit="$5" description="$6"
  local namespace="project-${project}"
  local created_at=$(date +%Y-%m-%d)
  local ingress_domain="${project}.${env}.${BASE_DOMAIN:-192.168.51.30.sslip.io}"
  
  # 检查项目是否已存在
  if find_project "$project" "$env" >/dev/null; then
    echo "错误: 项目 '$project' 在环境 '$env' 中已存在" >&2
    exit 1
  fi
  
  # 检查环境是否存在
  if ! csv_lookup "$env" >/dev/null; then
    echo "错误: 环境 '$env' 不存在于 config/environments.csv 中" >&2
    exit 1
  fi
  
  echo "[PROJECT] 创建项目: $project (环境: $env)"
  
  # 获取集群上下文
  local provider=$(provider_for "$env")
  local ctx="$([ "$provider" = "k3d" ] && echo "k3d-${env}" || echo "kind-${env}")"
  
  # 检查集群是否存在
  if ! kubectl config get-contexts | grep -q "$ctx"; then
    echo "错误: 集群上下文 '$ctx' 不存在，请先创建环境 '$env'" >&2
    exit 1
  fi
  
  # 创建命名空间和资源配额
  echo "[PROJECT] 创建命名空间: $namespace"
  sed -e "s/PROJECT_NAMESPACE_PLACEHOLDER/$namespace/g" \
      -e "s/PROJECT_NAME_PLACEHOLDER/$project/g" \
      -e "s/PROJECT_TEAM_PLACEHOLDER/$team/g" \
      -e "s/PROJECT_ENV_PLACEHOLDER/$env/g" \
      -e "s/PROJECT_CREATED_AT_PLACEHOLDER/$created_at/g" \
      -e "s/PROJECT_DESCRIPTION_PLACEHOLDER/$description/g" \
      -e "s/PROJECT_CPU_LIMIT_PLACEHOLDER/$cpu_limit/g" \
      -e "s/PROJECT_MEMORY_LIMIT_PLACEHOLDER/$memory_limit/g" \
      "$ROOT_DIR/manifests/project-template/namespace.yaml" | \
    kubectl --context "$ctx" apply -f -
  
  # 创建资源配额
  echo "[PROJECT] 创建资源配额"
  sed -e "s/PROJECT_NAMESPACE_PLACEHOLDER/$namespace/g" \
      -e "s/PROJECT_CPU_LIMIT_PLACEHOLDER/$cpu_limit/g" \
      -e "s/PROJECT_MEMORY_LIMIT_PLACEHOLDER/$memory_limit/g" \
      "$ROOT_DIR/manifests/project-template/resourcequota.yaml" | \
    kubectl --context "$ctx" apply -f -
  
  # 创建限制范围
  echo "[PROJECT] 创建限制范围"
  sed -e "s/PROJECT_NAMESPACE_PLACEHOLDER/$namespace/g" \
      "$ROOT_DIR/manifests/project-template/limitrange.yaml" | \
    kubectl --context "$ctx" apply -f -
  
  # 创建网络策略
  echo "[PROJECT] 创建网络策略"
  sed -e "s/PROJECT_NAMESPACE_PLACEHOLDER/$namespace/g" \
      "$ROOT_DIR/manifests/project-template/networkpolicy.yaml" | \
    kubectl --context "$ctx" apply -f -
  
  # 添加到 projects.csv
  echo "[PROJECT] 更新项目配置"
  echo "$project,$env,$namespace,$team,$cpu_limit,$memory_limit,$ingress_domain,$created_at,$description" >> "$PROJECTS_CSV"
  
  echo "[PROJECT] 项目 '$project' 创建成功"
  echo "  - 命名空间: $namespace"
  echo "  - 环境: $env"
  echo "  - 团队: $team"
  echo "  - CPU 限制: $cpu_limit"
  echo "  - 内存限制: $memory_limit"
  echo "  - 域名: $ingress_domain"
}

# 查看项目详情
show_project() {
  local project="$1" env="$2"
  
  if ! project_config=$(find_project "$project" "$env"); then
    echo "错误: 项目 '$project' 在环境 '$env' 中不存在" >&2
    exit 1
  fi
  
  IFS=, read -r p_name p_env p_namespace p_team p_cpu p_memory p_domain p_created p_desc <<<"$project_config"
  
  echo "项目详情:"
  echo "  名称: $p_name"
  echo "  环境: $p_env"
  echo "  命名空间: $p_namespace"
  echo "  团队: $p_team"
  echo "  CPU 限制: $p_cpu"
  echo "  内存限制: $p_memory"
  echo "  域名: $p_domain"
  echo "  创建时间: $p_created"
  echo "  描述: $p_desc"
  
  # 获取集群上下文
  local provider=$(provider_for "$env")
  local ctx="$([ "$provider" = "k3d" ] && echo "k3d-${env}" || echo "kind-${env}")"
  
  # 检查命名空间状态
  if kubectl --context "$ctx" get namespace "$p_namespace" >/dev/null 2>&1; then
    echo "  状态: 已部署"
    
    # 显示资源使用情况
    echo "  资源使用:"
    kubectl --context "$ctx" -n "$p_namespace" get resourcequota -o custom-columns="NAME:.metadata.name,CPU:.spec.hard.requests\.cpu,MEMORY:.spec.hard.requests\.memory" 2>/dev/null || true
  else
    echo "  状态: 未部署"
  fi
}

# 更新项目配置
update_project() {
  local project="$1" cpu_limit="$2" memory_limit="$3" description="$4"
  
  echo "[PROJECT] 更新项目配置: $project"
  
  # 查找所有环境中的项目
  local projects_found=()
  while IFS=, read -r p_name p_env p_namespace p_team p_cpu p_memory p_domain p_created p_desc; do
    if [ "$p_name" = "$project" ]; then
      projects_found+=("$p_env")
      
      # 更新配置
      local new_cpu="${cpu_limit:-$p_cpu}"
      local new_memory="${memory_limit:-$p_memory}"
      local new_desc="${description:-$p_desc}"
      
      # 更新命名空间注解
      local provider=$(provider_for "$p_env")
      local ctx="$([ "$provider" = "k3d" ] && echo "k3d-${p_env}" || echo "kind-${p_env}")"
      
      kubectl --context "$ctx" annotate namespace "$p_namespace" \
        kindler.io/cpu-limit="$new_cpu" \
        kindler.io/memory-limit="$new_memory" \
        kindler.io/project-description="$new_desc" \
        --overwrite >/dev/null 2>&1 || true
      
      # 更新资源配额
      kubectl --context "$ctx" patch resourcequota project-quota -n "$p_namespace" -p "{
        \"spec\": {
          \"hard\": {
            \"requests.cpu\": \"$new_cpu\",
            \"requests.memory\": \"$new_memory\",
            \"limits.cpu\": \"$new_cpu\",
            \"limits.memory\": \"$new_memory\"
          }
        }
      }" >/dev/null 2>&1 || true
    fi
  done < <(parse_projects_csv)
  
  if [ ${#projects_found[@]} -eq 0 ]; then
    echo "错误: 项目 '$project' 不存在" >&2
    exit 1
  fi
  
  echo "[PROJECT] 项目 '$project' 配置已更新"
  echo "  更新的环境: ${projects_found[*]}"
}

# 删除项目
delete_project() {
  local project="$1" env="$2"
  
  if ! project_config=$(find_project "$project" "$env"); then
    echo "错误: 项目 '$project' 在环境 '$env' 中不存在" >&2
    exit 1
  fi
  
  IFS=, read -r p_name p_env p_namespace p_team p_cpu p_memory p_domain p_created p_desc <<<"$project_config"
  
  echo "[PROJECT] 删除项目: $project (环境: $env)"
  
  # 获取集群上下文
  local provider=$(provider_for "$env")
  local ctx="$([ "$provider" = "k3d" ] && echo "k3d-${env}" || echo "kind-${env}")"
  
  # 删除命名空间（这会删除所有相关资源）
  echo "[PROJECT] 删除命名空间: $p_namespace"
  kubectl --context "$ctx" delete namespace "$p_namespace" --ignore-not-found=true
  
  # 从 projects.csv 中移除
  echo "[PROJECT] 更新项目配置"
  local tmp_file=$(mktemp)
  parse_projects_csv | awk -F, -v p="$project" -v e="$env" '$1!=p || $2!=e {print}' > "$tmp_file"
  mv "$tmp_file" "$PROJECTS_CSV"
  
  echo "[PROJECT] 项目 '$project' 已删除"
}

# 生成项目 kubeconfig
generate_kubeconfig() {
  local project="$1" env="$2" output_file="$3"
  
  if ! project_config=$(find_project "$project" "$env"); then
    echo "错误: 项目 '$project' 在环境 '$env' 中不存在" >&2
    exit 1
  fi
  
  IFS=, read -r p_name p_env p_namespace p_team p_cpu p_memory p_domain p_created p_desc <<<"$project_config"
  
  echo "[PROJECT] 生成 kubeconfig: $project (环境: $env)"
  
  # 获取集群上下文
  local provider=$(provider_for "$env")
  local ctx="$([ "$provider" = "k3d" ] && echo "k3d-${env}" || echo "kind-${env}")"
  
  # 创建 ServiceAccount
  local sa_name="project-${project}-sa"
  kubectl --context "$ctx" -n "$p_namespace" create serviceaccount "$sa_name" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
  
  # 创建 Role
  kubectl --context "$ctx" -n "$p_namespace" create role "project-${project}-role" \
    --verb=get,list,watch,create,update,patch,delete \
    --resource=pods,services,deployments,ingresses,configmaps,secrets \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
  
  # 创建 RoleBinding
  kubectl --context "$ctx" -n "$p_namespace" create rolebinding "project-${project}-binding" \
    --role="project-${project}-role" \
    --serviceaccount="$p_namespace:$sa_name" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
  
  # 获取 ServiceAccount token
  local token_name=$(kubectl --context "$ctx" -n "$p_namespace" get serviceaccount "$sa_name" -o jsonpath='{.secrets[0].name}')
  local token=$(kubectl --context "$ctx" -n "$p_namespace" get secret "$token_name" -o jsonpath='{.data.token}' | base64 -d)
  
  # 获取集群信息
  local cluster_server=$(kubectl --context "$ctx" config view -o jsonpath='{.clusters[?(@.name=="'$ctx'")].cluster.server}')
  local cluster_ca=$(kubectl --context "$ctx" config view --raw -o jsonpath='{.clusters[?(@.name=="'$ctx'")].cluster.certificate-authority-data}')
  
  # 生成 kubeconfig
  cat > "$output_file" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${ctx}-${project}
  cluster:
    server: $cluster_server
    certificate-authority-data: $cluster_ca
contexts:
- name: ${ctx}-${project}
  context:
    cluster: ${ctx}-${project}
    namespace: $p_namespace
    user: ${ctx}-${project}-user
current-context: ${ctx}-${project}
users:
- name: ${ctx}-${project}-user
  user:
    token: $token
EOF
  
  echo "[PROJECT] kubeconfig 已生成: $output_file"
  echo "  集群: $ctx"
  echo "  命名空间: $p_namespace"
  echo "  用户: ${ctx}-${project}-user"
}

# 主函数
main() {
  local command="$1"
  shift
  
  case "$command" in
    list)
      local env_filter=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --env) env_filter="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      list_projects "$env_filter"
      ;;
    create)
      local project="" env="" team="" cpu_limit="" memory_limit="" description=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          --env) env="$2"; shift 2 ;;
          --team) team="$2"; shift 2 ;;
          --cpu-limit) cpu_limit="$2"; shift 2 ;;
          --memory-limit) memory_limit="$2"; shift 2 ;;
          --description) description="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] && [ -n "$env" ] && [ -n "$team" ] && [ -n "$cpu_limit" ] && [ -n "$memory_limit" ] || usage
      create_project "$project" "$env" "$team" "$cpu_limit" "$memory_limit" "${description:-Project $project}"
      ;;
    show)
      local project="" env=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          --env) env="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] && [ -n "$env" ] || usage
      show_project "$project" "$env"
      ;;
    update)
      local project="" cpu_limit="" memory_limit="" description=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          --cpu-limit) cpu_limit="$2"; shift 2 ;;
          --memory-limit) memory_limit="$2"; shift 2 ;;
          --description) description="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] || usage
      update_project "$project" "$cpu_limit" "$memory_limit" "$description"
      ;;
    delete)
      local project="" env=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          --env) env="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] && [ -n "$env" ] || usage
      delete_project "$project" "$env"
      ;;
    kubeconfig)
      local project="" env="" output_file=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          --env) env="$2"; shift 2 ;;
          --output) output_file="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] && [ -n "$env" ] || usage
      output_file="${output_file:-~/.kube/${project}-${env}.yaml}"
      generate_kubeconfig "$project" "$env" "$output_file"
      ;;
    *)
      echo "未知命令: $command" >&2
      usage
      ;;
  esac
}

[ $# -lt 1 ] && usage
main "$@"

