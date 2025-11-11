#!/usr/bin/env bash
# Git 分支管理库
# 用于管理环境分支（env/*）

set -Eeuo pipefail

_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "${_LIB_DIR##*/}" in
  lib) ROOT_DIR="$(cd -- "${_LIB_DIR}/../.." && pwd)" ;;
  *)   ROOT_DIR="$(cd -- "${_LIB_DIR}/.." && pwd)" ;;
esac

# 列出所有 env/* 分支
# 参数：
#   $1: Git 仓库 URL
# 输出：分支名列表（每行一个）
list_env_branches() {
	local git_repo="$1"
	
	if [ -z "$git_repo" ]; then
		echo "[ERROR] Git repository URL is required" >&2
		return 1
	fi
	
	# 列出远程分支，过滤 env/* 前缀
	git ls-remote --heads "$git_repo" 2>/dev/null | \
		awk '{print $2}' | \
		grep '^refs/heads/env/' | \
		sed 's|^refs/heads/||' || true
}

# 创建环境分支
# 参数：
#   $1: 环境名（如 dev）
#   $2: Git 仓库 URL
#   $3: 基准分支（默认: develop）
#   $4-$n: .kindler.yaml 内容（可选，如果不提供则创建空分支）
# 返回：0=成功，1=失败
create_env_branch() {
	local env="$1"
	local git_repo="$2"
	local base_branch="${3:-develop}"
	local config_content="${4:-}"
	
	local branch="env/$env"
	local tmpdir
	
	tmpdir=$(mktemp -d)
	trap "rm -rf '$tmpdir'" EXIT
	
	echo "[GIT] Creating branch $branch from $base_branch..."
	
	# Clone 仓库
	if ! git clone "$git_repo" "$tmpdir" >/dev/null 2>&1; then
		echo "[ERROR] Failed to clone repository" >&2
		return 1
	fi
	
	cd "$tmpdir"
	
	# 检查分支是否已存在
	if git ls-remote --heads origin "$branch" | grep -q "$branch"; then
		echo "[ERROR] Branch $branch already exists" >&2
		return 1
	fi
	
	# 检查基准分支是否存在
	if ! git ls-remote --heads origin "$base_branch" | grep -q "$base_branch"; then
		echo "[WARN] Base branch $base_branch not found, using master/main"
		if git ls-remote --heads origin "main" | grep -q "main"; then
			base_branch="main"
		else
			base_branch="master"
		fi
	fi
	
	# 创建新分支
	git checkout -b "$branch" "origin/$base_branch" >/dev/null 2>&1
	
	# 如果提供了配置内容，创建 .kindler.yaml
	if [ -n "$config_content" ]; then
		echo "$config_content" > .kindler.yaml
		git add .kindler.yaml
		git commit -m "feat: initialize $env environment configuration" >/dev/null 2>&1
	fi
	
	# 推送到远程
	if ! git push origin "$branch" >/dev/null 2>&1; then
		echo "[ERROR] Failed to push branch $branch" >&2
		return 1
	fi
	
	echo "[GIT] Branch $branch created successfully"
	return 0
}

# 删除环境分支
# 参数：
#   $1: 环境名（如 dev）
#   $2: Git 仓库 URL
# 返回：0=成功，1=失败
delete_env_branch() {
	local env="$1"
	local git_repo="$2"
	
	local branch="env/$env"
	
	echo "[GIT] Deleting branch $branch..."
	
	# 检查分支是否存在
	if ! git ls-remote --heads "$git_repo" "$branch" 2>/dev/null | grep -q "$branch"; then
		echo "[WARN] Branch $branch does not exist"
		return 0
	fi
	
	# 删除远程分支
	if ! git push "$git_repo" --delete "$branch" 2>/dev/null; then
		echo "[ERROR] Failed to delete branch $branch" >&2
		return 1
	fi
	
	echo "[GIT] Branch $branch deleted successfully"
	return 0
}

# 更新分支配置
# 参数：
#   $1: 环境名（如 dev）
#   $2: 配置文件路径
#   $3: Git 仓库 URL
#   $4: 提交消息（可选）
# 返回：0=成功，1=失败
update_branch_config() {
	local env="$1"
	local config_file="$2"
	local git_repo="$3"
	local commit_msg="${4:-Update $env configuration}"
	
	local branch="env/$env"
	local tmpdir
	
	if [ ! -f "$config_file" ]; then
		echo "[ERROR] Config file not found: $config_file" >&2
		return 1
	fi
	
	tmpdir=$(mktemp -d)
	trap "rm -rf '$tmpdir'" EXIT
	
	echo "[GIT] Updating configuration for branch $branch..."
	
	# Clone 分支
	if ! git clone --depth 1 --branch "$branch" "$git_repo" "$tmpdir" >/dev/null 2>&1; then
		echo "[ERROR] Failed to clone branch $branch" >&2
		return 1
	fi
	
	cd "$tmpdir"
	
	# 更新配置文件
	cp "$config_file" .kindler.yaml
	
	# 检查是否有变更
	if git diff --quiet .kindler.yaml; then
		echo "[INFO] No changes detected"
		return 0
	fi
	
	# 提交并推送
	git add .kindler.yaml
	git commit -m "$commit_msg" >/dev/null 2>&1
	
	if ! git push origin "$branch" >/dev/null 2>&1; then
		echo "[ERROR] Failed to push changes" >&2
		return 1
	fi
	
	echo "[GIT] Configuration updated successfully"
	return 0
}

# 检查分支是否存在
# 参数：
#   $1: 环境名（如 dev）
#   $2: Git 仓库 URL
# 返回：0=存在，1=不存在
branch_exists() {
	local env="$1"
	local git_repo="$2"
	
	local branch="env/$env"
	
	git ls-remote --heads "$git_repo" "$branch" 2>/dev/null | grep -q "$branch"
}

# 从分支读取配置文件
# 参数：
#   $1: 环境名（如 dev）
#   $2: Git 仓库 URL
# 输出：配置文件内容
read_branch_file() {
	local env="$1"
	local git_repo="$2"
	
	local branch="env/$env"
	local tmpdir
	
	tmpdir=$(mktemp -d)
	trap "rm -rf '$tmpdir'" EXIT
	
	# Clone 分支
	if ! git clone --depth 1 --branch "$branch" "$git_repo" "$tmpdir" >/dev/null 2>&1; then
		echo "[ERROR] Failed to clone branch $branch" >&2
		return 1
	fi
	
	# 输出配置文件
	if [ ! -f "$tmpdir/.kindler.yaml" ]; then
		echo "[ERROR] .kindler.yaml not found in branch $branch" >&2
		return 1
	fi
	
	cat "$tmpdir/.kindler.yaml"
}

# 获取分支的最后提交信息
# 参数：
#   $1: 环境名（如 dev）
#   $2: Git 仓库 URL
# 输出：提交信息（commit hash + message）
get_branch_last_commit() {
	local env="$1"
	local git_repo="$2"
	
	local branch="env/$env"
	
	git ls-remote --heads "$git_repo" "$branch" 2>/dev/null | \
		awk '{print $1}' | \
		head -1
}

# 主函数（用于测试）
main() {
	if [ $# -eq 0 ]; then
		cat <<EOF
Usage: $0 <command> [arguments]

Commands:
  list <repo>                     列出所有环境分支
  create <env> <repo> [base]      创建环境分支
  delete <env> <repo>             删除环境分支
  update <env> <config> <repo>    更新分支配置
  exists <env> <repo>             检查分支是否存在
  read <env> <repo>               读取分支配置文件
  last-commit <env> <repo>        获取最后提交信息

Examples:
  $0 list http://git.example.com/repo.git
  $0 create dev http://git.example.com/repo.git develop
  $0 delete dev http://git.example.com/repo.git
  $0 exists dev http://git.example.com/repo.git
  $0 read dev http://git.example.com/repo.git
EOF
		exit 1
	fi
	
	local cmd="$1"
	shift
	
	case "$cmd" in
		list)
			list_env_branches "$@"
			;;
		create)
			create_env_branch "$@"
			;;
		delete)
			delete_env_branch "$@"
			;;
		update)
			update_branch_config "$@"
			;;
		exists)
			if branch_exists "$@"; then
				echo "Branch exists"
				exit 0
			else
				echo "Branch does not exist"
				exit 1
			fi
			;;
		read)
			read_branch_file "$@"
			;;
		last-commit)
			get_branch_last_commit "$@"
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

