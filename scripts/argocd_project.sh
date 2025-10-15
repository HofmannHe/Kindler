#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat >&2 <<USAGE
Usage: $0 <command> [options]

Commands:
  create --project <name> --repo <url> --namespace <ns>  # 创建 ArgoCD AppProject
  add-app --project <name> --app <app> --path <path> --env <env>  # 为项目添加应用
  list [--project <name>]                                # 列出 AppProject 或 Applications
  delete --project <name>                               # 删除 AppProject

Options:
  --project <name>   项目名称
  --repo <url>       Git 仓库 URL
  --namespace <ns>   目标命名空间
  --app <app>        应用名称
  --path <path>      应用路径
  --env <env>        环境名称

Examples:
  $0 create --project project-a --repo https://git.example.com/project-a/app.git --namespace project-a
  $0 add-app --project project-a --app whoami --path deploy/ --env dev
  $0 list
  $0 list --project project-a
  $0 delete --project project-a
USAGE
  exit 1
}

# 获取 ArgoCD 访问信息
get_argocd_info() {
  # 获取 ArgoCD 服务器地址
  local argocd_ip=$(docker inspect portainer-ce | jq -r '.[0].NetworkSettings.Networks | to_entries[0].value.IPAddress')
  local argocd_url="http://${argocd_ip}:30800"
  
  # 获取管理员密码
  local admin_password=""
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then
    . "$ROOT_DIR/config/secrets.env"
    admin_password="${ARGOCD_ADMIN_PASSWORD:-admin123}"
  else
    admin_password="admin123"
  fi
  
  echo "$argocd_url|$admin_password"
}

# 获取 ArgoCD JWT token
get_argocd_token() {
  local argocd_info=$(get_argocd_info)
  local argocd_url=$(echo "$argocd_info" | cut -d'|' -f1)
  local admin_password=$(echo "$argocd_info" | cut -d'|' -f2)
  
  local token=""
  for i in 1 2 3; do
    token=$(curl -sk -X POST "$argocd_url/api/v1/session" \
      -H "Content-Type: application/json" \
      -d "{\"username\": \"admin\", \"password\": \"$admin_password\"}" | \
      jq -r '.token' 2>/dev/null || true)
    [ -n "$token" ] && [ "$token" != "null" ] && break
    sleep 2
  done
  
  echo "$token"
}

# 创建 AppProject
create_appproject() {
  local project="$1" repo_url="$2" namespace="$3"
  
  echo "[ARGOCD] 创建 AppProject: $project"
  
  local token=$(get_argocd_token)
  [ -z "$token" ] && {
    echo "错误: 无法获取 ArgoCD token" >&2
    exit 1
  }
  
  local argocd_info=$(get_argocd_info)
  local argocd_url=$(echo "$argocd_info" | cut -d'|' -f1)
  
  # 创建 AppProject
  local appproject_yaml=$(cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $project
  namespace: argocd
spec:
  description: Project $project applications
  sourceRepos:
  - '$repo_url'
  destinations:
  - namespace: '$namespace'
    server: '*'
  clusterResourceWhitelist:
  - group: ''
    kind: Namespace
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
  roles:
  - name: $project-admin
    policies:
    - p, proj:$project:admin, applications, *, $project/*, allow
    - p, proj:$project:admin, repositories, *, *, allow
    groups:
    - $project-admins
EOF
)
  
  # 通过 kubectl 应用
  echo "$appproject_yaml" | kubectl --context k3d-devops apply -f -
  
  echo "[ARGOCD] AppProject '$project' 创建成功"
  echo "  - 仓库: $repo_url"
  echo "  - 命名空间: $namespace"
}

# 为项目添加应用
add_application() {
  local project="$1" app="$2" path="$3" env="$4"
  
  echo "[ARGOCD] 为项目 '$project' 添加应用: $app"
  
  # 获取项目配置
  local project_config=""
  if [ -f "$ROOT_DIR/config/projects.csv" ]; then
    project_config=$(awk -F, -v p="$project" -v e="$env" '$1==p && $2==e {print; exit}' "$ROOT_DIR/config/projects.csv")
  fi
  
  if [ -z "$project_config" ]; then
    echo "错误: 项目 '$project' 在环境 '$env' 中不存在" >&2
    exit 1
  fi
  
  IFS=, read -r p_name p_env p_namespace p_team p_cpu p_memory p_domain p_created p_desc <<<"$project_config"
  
  # 获取集群信息
  local provider=$(provider_for "$env")
  local cluster_name="$([ "$provider" = "k3d" ] && echo "k3d-${env}" || echo "kind-${env}")"
  
  # 获取 Git 仓库信息
  local repo_url=""
  if [ -f "$ROOT_DIR/config/git.env" ]; then
    . "$ROOT_DIR/config/git.env"
    repo_url="${GIT_REPO_URL:-}"
  fi
  
  if [ -z "$repo_url" ]; then
    echo "错误: 未配置 Git 仓库 URL (config/git.env)" >&2
    exit 1
  fi
  
  # 创建 Application
  local application_yaml=$(cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $app-$env
  namespace: argocd
  labels:
    project: $project
    environment: $env
spec:
  project: $project
  source:
    repoURL: $repo_url
    targetRevision: HEAD
    path: $path
  destination:
    server: https://kubernetes.default.svc
    namespace: $p_namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - PruneLast=true
EOF
)
  
  # 通过 kubectl 应用
  echo "$application_yaml" | kubectl --context k3d-devops apply -f -
  
  echo "[ARGOCD] 应用 '$app' 已添加到项目 '$project'"
  echo "  - 环境: $env"
  echo "  - 命名空间: $p_namespace"
  echo "  - 路径: $path"
}

# 列出 AppProject 或 Applications
list_items() {
  local project_filter="$1"
  
  if [ -n "$project_filter" ]; then
    echo "项目 '$project_filter' 的应用列表:"
    kubectl --context k3d-devops -n argocd get applications -l project="$project_filter" -o custom-columns="NAME:.metadata.name,PROJECT:.spec.project,NAMESPACE:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status" 2>/dev/null || true
  else
    echo "所有 AppProject:"
    kubectl --context k3d-devops -n argocd get appprojects -o custom-columns="NAME:.metadata.name,DESCRIPTION:.spec.description,REPOS:.spec.sourceRepos" 2>/dev/null || true
    
    echo ""
    echo "所有 Applications:"
    kubectl --context k3d-devops -n argocd get applications -o custom-columns="NAME:.metadata.name,PROJECT:.spec.project,NAMESPACE:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status" 2>/dev/null || true
  fi
}

# 删除 AppProject
delete_appproject() {
  local project="$1"
  
  echo "[ARGOCD] 删除 AppProject: $project"
  
  # 删除所有相关的 Applications
  echo "[ARGOCD] 删除相关应用..."
  kubectl --context k3d-devops -n argocd delete applications -l project="$project" --ignore-not-found=true
  
  # 删除 AppProject
  kubectl --context k3d-devops -n argocd delete appproject "$project" --ignore-not-found=true
  
  echo "[ARGOCD] AppProject '$project' 已删除"
}

# 主函数
main() {
  local command="$1"
  shift
  
  case "$command" in
    create)
      local project="" repo="" namespace=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          --repo) repo="$2"; shift 2 ;;
          --namespace) namespace="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] && [ -n "$repo" ] && [ -n "$namespace" ] || usage
      create_appproject "$project" "$repo" "$namespace"
      ;;
    add-app)
      local project="" app="" path="" env=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          --app) app="$2"; shift 2 ;;
          --path) path="$2"; shift 2 ;;
          --env) env="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] && [ -n "$app" ] && [ -n "$path" ] && [ -n "$env" ] || usage
      add_application "$project" "$app" "$path" "$env"
      ;;
    list)
      local project_filter=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project_filter="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      list_items "$project_filter"
      ;;
    delete)
      local project=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) project="$2"; shift 2 ;;
          *) echo "未知选项: $1" >&2; usage ;;
        esac
      done
      [ -n "$project" ] || usage
      delete_appproject "$project"
      ;;
    *)
      echo "未知命令: $command" >&2
      usage
      ;;
  esac
}

[ $# -lt 1 ] && usage
main "$@"
