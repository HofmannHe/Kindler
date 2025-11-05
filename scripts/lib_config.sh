#!/usr/bin/env bash
# Git 分支配置解析库
# 用于解析和验证 .kindler.yaml 配置文件

set -Eeuo pipefail

# 从 Git 分支读取 .kindler.yaml
# 参数：
#   $1: 分支名（如 env/dev）
#   $2: Git 仓库 URL
# 输出：JSON 格式配置
read_branch_config() {
	local branch="$1"
	local git_repo="$2"
	local tmpdir
	
	tmpdir=$(mktemp -d)
	trap "rm -rf '$tmpdir'" EXIT
	
	# Clone 指定分支到临时目录
	if ! git clone --depth 1 --branch "$branch" "$git_repo" "$tmpdir" >/dev/null 2>&1; then
		echo "[ERROR] Failed to clone branch $branch from $git_repo" >&2
		return 1
	fi
	
	# 检查 .kindler.yaml 是否存在
	if [ ! -f "$tmpdir/.kindler.yaml" ]; then
		echo "[ERROR] .kindler.yaml not found in branch $branch" >&2
		return 1
	fi
	
	# 解析并返回 JSON
	read_local_config "$tmpdir/.kindler.yaml"
}

# 从本地文件读取配置
# 参数：
#   $1: 配置文件路径
# 输出：JSON 格式配置
read_local_config() {
	local config_file="$1"
	
	if [ ! -f "$config_file" ]; then
		echo "[ERROR] Config file not found: $config_file" >&2
		return 1
	fi
	
	# 使用 python yaml 解析（更可靠）
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$config_file" <<'PYTHON'
import sys
import json
import yaml

try:
    with open(sys.argv[1], 'r') as f:
        config = yaml.safe_load(f)
    print(json.dumps(config, indent=2))
except Exception as e:
    print(f"[ERROR] Failed to parse YAML: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
	else
		echo "[ERROR] python3 not found, cannot parse YAML" >&2
		return 1
	fi
}

# 验证配置完整性
# 参数：
#   $1: 配置 JSON 字符串
# 返回：0=有效，1=无效
validate_config() {
	local config_json="$1"
	local errors=0
	
	# 检查必需字段
	if ! echo "$config_json" | jq -e '.version' >/dev/null 2>&1; then
		echo "[ERROR] Missing required field: version" >&2
		errors=$((errors + 1))
	fi
	
	if ! echo "$config_json" | jq -e '.cluster.provider' >/dev/null 2>&1; then
		echo "[ERROR] Missing required field: cluster.provider" >&2
		errors=$((errors + 1))
	fi
	
	if ! echo "$config_json" | jq -e '.network.http_port' >/dev/null 2>&1; then
		echo "[ERROR] Missing required field: network.http_port" >&2
		errors=$((errors + 1))
	fi
	
	if ! echo "$config_json" | jq -e '.network.https_port' >/dev/null 2>&1; then
		echo "[ERROR] Missing required field: network.https_port" >&2
		errors=$((errors + 1))
	fi
	
	if ! echo "$config_json" | jq -e '.network.node_port' >/dev/null 2>&1; then
		echo "[ERROR] Missing required field: network.node_port" >&2
		errors=$((errors + 1))
	fi
	
	# 检查 provider 值
	local provider
	provider=$(echo "$config_json" | jq -r '.cluster.provider // empty')
	if [ -n "$provider" ] && [ "$provider" != "k3d" ] && [ "$provider" != "kind" ]; then
		echo "[ERROR] Invalid cluster.provider: $provider (must be k3d or kind)" >&2
		errors=$((errors + 1))
	fi
	
	# 检查端口范围
	local http_port https_port node_port
	http_port=$(echo "$config_json" | jq -r '.network.http_port // 0')
	https_port=$(echo "$config_json" | jq -r '.network.https_port // 0')
	node_port=$(echo "$config_json" | jq -r '.network.node_port // 0')
	
	if [ "$http_port" -lt 1024 ] || [ "$http_port" -gt 65535 ]; then
		echo "[ERROR] Invalid network.http_port: $http_port (must be 1024-65535)" >&2
		errors=$((errors + 1))
	fi
	
	if [ "$https_port" -lt 1024 ] || [ "$https_port" -gt 65535 ]; then
		echo "[ERROR] Invalid network.https_port: $https_port (must be 1024-65535)" >&2
		errors=$((errors + 1))
	fi
	
	if [ "$node_port" -lt 30000 ] || [ "$node_port" -gt 32767 ]; then
		echo "[ERROR] Invalid network.node_port: $node_port (must be 30000-32767)" >&2
		errors=$((errors + 1))
	fi
	
	# 检查子网格式（如果指定）
	local subnet
	subnet=$(echo "$config_json" | jq -r '.network.subnet // empty')
	if [ -n "$subnet" ] && ! echo "$subnet" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
		echo "[ERROR] Invalid network.subnet format: $subnet (must be CIDR notation)" >&2
		errors=$((errors + 1))
	fi
	
	if [ "$errors" -gt 0 ]; then
		echo "[ERROR] Config validation failed with $errors error(s)" >&2
		return 1
	fi
	
	echo "[OK] Config validation passed"
	return 0
}

# 从环境名提取分支名
# 参数：
#   $1: 环境名（如 dev）
# 输出：分支名（如 env/dev）
env_to_branch() {
	local env="$1"
	echo "env/$env"
}

# 从分支名提取环境名
# 参数：
#   $1: 分支名（如 env/dev）
# 输出：环境名（如 dev）
branch_to_env() {
	local branch="$1"
	echo "${branch#env/}"
}

# 从配置 JSON 提取字段值
# 参数：
#   $1: 配置 JSON 字符串
#   $2: JSON 路径（如 .cluster.provider）
# 输出：字段值
get_config_value() {
	local config_json="$1"
	local json_path="$2"
	
	echo "$config_json" | jq -r "$json_path // empty"
}

# 主函数（用于测试）
main() {
	if [ $# -eq 0 ]; then
		cat <<EOF
Usage: $0 <command> [arguments]

Commands:
  read <file>                读取本地配置文件
  read-branch <branch> <repo> 从 Git 分支读取配置
  validate <file>            验证配置文件
  env-to-branch <env>        环境名转分支名
  branch-to-env <branch>     分支名转环境名

Examples:
  $0 read examples/kindler-config/.kindler.yaml
  $0 read-branch env/dev http://git.example.com/repo.git
  $0 validate examples/kindler-config/.kindler.yaml
  $0 env-to-branch dev
  $0 branch-to-env env/dev
EOF
		exit 1
	fi
	
	local cmd="$1"
	shift
	
	case "$cmd" in
		read)
			read_local_config "$@"
			;;
		read-branch)
			read_branch_config "$@"
			;;
		validate)
			local config_json
			config_json=$(read_local_config "$1")
			validate_config "$config_json"
			;;
		env-to-branch)
			env_to_branch "$@"
			;;
		branch-to-env)
			branch_to_env "$@"
			;;
		*)
			echo "[ERROR] Unknown command: $cmd" >&2
			exit 1
			;;
	esac
}

# 如果直接执行（非 source），运行主函数
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	main "$@"
fi


