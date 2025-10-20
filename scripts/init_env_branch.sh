#!/usr/bin/env bash
# 初始化环境分支
# 创建 Git 环境分支（env/*）并生成 .kindler.yaml 配置文件

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 加载库
source "$ROOT_DIR/scripts/lib_git.sh"
source "$ROOT_DIR/scripts/lib_config.sh"

# 默认值
DEFAULT_NODE_PORT=30080
DEFAULT_BASE_BRANCH="develop"

usage() {
	cat <<EOF
Usage: $0 -n <env-name> -p <provider> [options]

初始化 Git 环境分支并创建配置文件

Required:
  -n, --name <name>          环境名称
  -p, --provider <provider>  k3d 或 kind

Optional:
  --http-port <port>         HAProxy HTTP 端口
  --https-port <port>        HAProxy HTTPS 端口
  --node-port <port>         Kubernetes NodePort (默认: 30080)
  --pf-port <port>           Port-forward 端口
  --subnet <cidr>            k3d 子网（CIDR 格式，可选）
  --base-branch <branch>     基准分支 (默认: develop)
  --portainer-tags <tags>    Portainer 标签（逗号分隔）
  --argocd-labels <labels>   ArgoCD 标签（key=value 格式，逗号分隔）
  --git-repo <url>           Git 仓库 URL（默认从 config/git.env 读取）

Examples:
  # 最小配置
  $0 -n myenv -p k3d --http-port 19100 --https-port 19200

  # 完整配置
  $0 -n myenv -p k3d \\
    --http-port 19100 --https-port 19200 \\
    --subnet 10.104.0.0/16 \\
    --portainer-tags "myenv,k3d,test" \\
    --argocd-labels "env=myenv,provider=k3d"
EOF
	exit 1
}

# 生成 .kindler.yaml 配置内容
generate_config() {
	local env="$1" provider="$2" http_port="$3" https_port="$4"
	local node_port="${5:-$DEFAULT_NODE_PORT}" pf_port="${6:-}" subnet="${7:-}"
	local portainer_tags="${8:-}" argocd_labels="${9:-}"
	
	# 生成 Portainer tags 数组
	local tags_yaml="[]"
	if [ -n "$portainer_tags" ]; then
		tags_yaml="["
		IFS=',' read -ra TAGS <<< "$portainer_tags"
		for i in "${!TAGS[@]}"; do
			[ $i -gt 0 ] && tags_yaml+=", "
			tags_yaml+="\"${TAGS[$i]}\""
		done
		tags_yaml+="]"
	else
		# 默认标签
		tags_yaml="[\"$env\", \"$provider\", \"business\"]"
	fi
	
	# 生成 ArgoCD labels
	local labels_yaml=""
	if [ -n "$argocd_labels" ]; then
		IFS=',' read -ra LABELS <<< "$argocd_labels"
		for label in "${LABELS[@]}"; do
			key="${label%%=*}"
			value="${label#*=}"
			labels_yaml+="      $key: $value"$'\n'
		done
	else
		# 默认标签
		labels_yaml="      env: $env"$'\n'
		labels_yaml+="      provider: $provider"$'\n'
		labels_yaml+="      type: business"$'\n'
	fi
	
	# 生成完整配置
	cat <<EOF
version: v1

cluster:
  provider: $provider

network:
  http_port: $http_port
  https_port: $https_port
  node_port: $node_port
EOF
	
	# pf_port 可选
	if [ -n "$pf_port" ]; then
		echo "  pf_port: $pf_port"
	fi
	
	# subnet 可选
	echo "  subnet: \"$subnet\""
	
	cat <<EOF

integrations:
  portainer:
    enabled: true
    tags: $tags_yaml
  
  haproxy:
    enabled: true
  
  argocd:
    enabled: true
    labels:
$labels_yaml
EOF
}

# 主函数
main() {
	# 解析参数
	local env="" provider="" http_port="" https_port=""
	local node_port="$DEFAULT_NODE_PORT" pf_port="" subnet=""
	local base_branch="$DEFAULT_BASE_BRANCH"
	local portainer_tags="" argocd_labels=""
	local git_repo=""
	
	while [ $# -gt 0 ]; do
		case "$1" in
			-n|--name)
				env="$2"
				shift 2
				;;
			-p|--provider)
				provider="$2"
				shift 2
				;;
			--http-port)
				http_port="$2"
				shift 2
				;;
			--https-port)
				https_port="$2"
				shift 2
				;;
			--node-port)
				node_port="$2"
				shift 2
				;;
			--pf-port)
				pf_port="$2"
				shift 2
				;;
			--subnet)
				subnet="$2"
				shift 2
				;;
			--base-branch)
				base_branch="$2"
				shift 2
				;;
			--portainer-tags)
				portainer_tags="$2"
				shift 2
				;;
			--argocd-labels)
				argocd_labels="$2"
				shift 2
				;;
			--git-repo)
				git_repo="$2"
				shift 2
				;;
			-h|--help)
				usage
				;;
			*)
				echo "[ERROR] Unknown option: $1" >&2
				usage
				;;
		esac
	done
	
	# 验证必需参数
	if [ -z "$env" ] || [ -z "$provider" ] || [ -z "$http_port" ] || [ -z "$https_port" ]; then
		echo "[ERROR] Missing required parameters" >&2
		usage
	fi
	
	# 验证 provider
	if [ "$provider" != "k3d" ] && [ "$provider" != "kind" ]; then
		echo "[ERROR] Invalid provider: $provider (must be k3d or kind)" >&2
		exit 1
	fi
	
	# 读取 Git 仓库配置
	if [ -z "$git_repo" ]; then
		if [ -f "$ROOT_DIR/config/git.env" ]; then
			source "$ROOT_DIR/config/git.env"
			git_repo="$GIT_REPO_URL"
		else
			echo "[ERROR] Git repository URL not specified and config/git.env not found" >&2
			exit 1
		fi
	fi
	
	if [ -z "$git_repo" ]; then
		echo "[ERROR] Git repository URL is required" >&2
		exit 1
	fi
	
	# 检查分支是否已存在
	if branch_exists "$env" "$git_repo"; then
		echo "[ERROR] Branch env/$env already exists in $git_repo" >&2
		echo "[ERROR] Use 'scripts/lib_git.sh update' to modify existing configuration" >&2
		exit 1
	fi
	
	echo "==========================================
"
	echo "  Environment Branch Initialization"
	echo "=========================================="
	echo ""
	echo "Environment: $env"
	echo "Provider: $provider"
	echo "Git Repo: $git_repo"
	echo "Base Branch: $base_branch"
	echo ""
	echo "Network Configuration:"
	echo "  HTTP Port: $http_port"
	echo "  HTTPS Port: $https_port"
	echo "  Node Port: $node_port"
	[ -n "$pf_port" ] && echo "  Port-forward Port: $pf_port"
	[ -n "$subnet" ] && echo "  Subnet: $subnet"
	echo ""
	
	# 生成配置文件
	echo "[INIT] Generating .kindler.yaml..."
	local config_content
	config_content=$(generate_config "$env" "$provider" "$http_port" "$https_port" \
		"$node_port" "$pf_port" "$subnet" "$portainer_tags" "$argocd_labels")
	
	# 验证配置
	echo "[INIT] Validating configuration..."
	local config_json
	config_json=$(echo "$config_content" | python3 -c "import sys, yaml, json; print(json.dumps(yaml.safe_load(sys.stdin)))")
	if ! validate_config "$config_json"; then
		echo "[ERROR] Configuration validation failed" >&2
		exit 1
	fi
	
	# 创建分支
	echo "[INIT] Creating branch env/$env..."
	if ! create_env_branch "$env" "$git_repo" "$base_branch" "$config_content"; then
		echo "[ERROR] Failed to create branch" >&2
		exit 1
	fi
	
	echo ""
	echo "=========================================="
	echo "✅ Branch env/$env initialized successfully!"
	echo "=========================================="
	echo ""
	echo "Next steps:"
	echo "  1. Review configuration:"
	echo "     bash scripts/lib_git.sh read $env $git_repo"
	echo ""
	echo "  2. Create cluster from Git config:"
	echo "     bash scripts/create_env.sh -n $env --git-mode"
	echo ""
}

main "$@"


