#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"

CONFIG_FILE="$ROOT_DIR/config/git.env"
EXAMPLE_DIR="$ROOT_DIR/examples/whoami"

log() { echo "[setup_git] $*"; }

require_config() {
  # 加载集群基础配置（提供 BASE_DOMAIN 等用于 git.env 变量展开）
  load_env
  if [ ! -f "$CONFIG_FILE" ]; then
    log "❌ 未找到配置文件 $CONFIG_FILE (请复制 config/git.env.example 并填写)"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then
    # shellcheck disable=SC1090
    . "$ROOT_DIR/config/secrets.env"
  fi

  : "${GIT_SERVER_URL:?请在 config/git.env 中设置 GIT_SERVER_URL}"
  : "${GIT_REPO_URL:?请在 config/git.env 中设置 GIT_REPO_URL}"

  GIT_USERNAME="${GIT_USERNAME:-}"
  GIT_PASSWORD="${GIT_PASSWORD:-}"
  GIT_DEFAULT_BRANCH="${GIT_DEFAULT_BRANCH:-main}"
  GIT_SEED_BRANCHES="${GIT_SEED_BRANCHES:-main develop release master}"
  GIT_COMMIT_NAME="${GIT_COMMIT_NAME:-Kindler Bot}"
  GIT_COMMIT_EMAIL="${GIT_COMMIT_EMAIL:-kindler@example.com}"
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"
}

with_credentials() {
  local url="$1"
  if [[ "$url" =~ ^https?:// ]] && [ -n "$GIT_USERNAME" ]; then
    local scheme="${url%%://*}"
    local rest="${url#*://}"
    local user_enc; user_enc=$(urlencode "$GIT_USERNAME")
    if [ -n "$GIT_PASSWORD" ]; then
      local pass_enc; pass_enc=$(urlencode "$GIT_PASSWORD")
      printf '%s://%s:%s@%s\n' "$scheme" "$user_enc" "$pass_enc" "$rest"
    else
      printf '%s://%s@%s\n' "$scheme" "$user_enc" "$rest"
    fi
  else
    printf '%s\n' "$url"
  fi
}

ls_remote() {
  local url="$1"
  if git ls-remote "$url" >/dev/null 2>&1; then
    return 0
  fi
  # Fallback: 通过 127.0.0.1 + Host 头访问 HAProxy（适配 sslip.io 场景）
  local host
  host=$(printf '%s' "$url" | sed -E 's#^https?://([^/]+)/.*#\1#')
  if printf '%s' "$host" | grep -q '\.sslip\.io$'; then
    if git -c http.extraHeader="Host: $host" ls-remote "$(echo "$url" | sed -E 's#^https?://[^/]+/#http://127.0.0.1/#')" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# GitLab API helpers (HTTP via HAProxy using Host header)
gitlab_api() {
  local method="$1" path="$2" data="${3:-}" header_token
  local base="$GIT_SERVER_URL" host url
  host=$(printf '%s' "$base" | sed -E 's#^https?://([^/]+)/?.*#\1#')
  url=$(printf '%s' "$base" | sed -E 's#^https?://[^/]+##')
  url="http://127.0.0.1${url}${path}"
  header_token="PRIVATE-TOKEN: ${GITLAB_TOKEN:-$GIT_PASSWORD}"
  if [ -n "$data" ]; then
    curl -sS -H "Host: $host" -H "$header_token" -H 'Content-Type: application/json' -X "$method" --data "$data" "$url"
  else
    curl -sS -H "Host: $host" -H "$header_token" -X "$method" "$url"
  fi
}

ensure_gitlab_project_exists() {
  # Parse group and project from GIT_REPO_URL: http(s)://host/<group>/<project>.git
  local path group project
  path=$(printf '%s' "$GIT_REPO_URL" | sed -E 's#^https?://[^/]+/##; s#\.git$##')
  group=$(printf '%s' "$path" | cut -d'/' -f1)
  project=$(printf '%s' "$path" | cut -d'/' -f2)
  [ -n "$project" ] || return 0

  # If ls-remote works, project exists
  if ls_remote "$(with_credentials "$GIT_REPO_URL")"; then
    return 0
  fi

  # Find group id
  local groups gid
  groups=$(gitlab_api GET "/api/v4/groups?search=${group}") || true
  gid=$(echo "$groups" | jq -r ".[0].id" 2>/dev/null || echo "null")
  if [ -z "$gid" ] || [ "$gid" = "null" ]; then
    # Try to create group if token allows (optional)
    created=$(gitlab_api POST "/api/v4/groups" "{\"name\":\"${group}\",\"path\":\"${group}\"}") || true
    gid=$(echo "$created" | jq -r ".id" 2>/dev/null || echo "null")
  fi

  # Create project if not exists
  local payload
  if [ "$gid" != "null" ] && [ -n "$gid" ]; then
    payload=$(printf '{"name":"%s","path":"%s","namespace_id":%s}' "$project" "$project" "$gid")
  else
    payload=$(printf '{"name":"%s","path":"%s"}' "$project" "$project")
  fi
  gitlab_api POST "/api/v4/projects" "$payload" >/dev/null 2>&1 || true

  # Re-check
  ls_remote "$(with_credentials "$GIT_REPO_URL")" || return 1
}

repo_default_branch() {
  local dir="$1"
  local def
  def=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  if [ -z "$def" ]; then
    # try common names
    for b in main master develop; do
      git -C "$dir" rev-parse --verify "origin/$b" >/dev/null 2>&1 && { echo "$b"; return; }
    done
  else
    echo "$def"; return
  fi
  echo "$GIT_DEFAULT_BRANCH"
}

ensure_whoami_chart_in_branch() {
  local dir="$1" branch="$2"
  git -C "$dir" checkout -q "$branch" 2>/dev/null || git -C "$dir" checkout -q -b "$branch" "origin/$branch" 2>/dev/null || git -C "$dir" checkout -q -b "$branch" "$GIT_DEFAULT_BRANCH" 2>/dev/null || true
  if [ ! -f "$dir/deploy/Chart.yaml" ]; then
    mkdir -p "$dir/deploy"
    cp -R "$EXAMPLE_DIR"/deploy/. "$dir/deploy/"
    git -C "$dir" add deploy
    git -C "$dir" commit -m "feat: add whoami helm chart to $branch" >/dev/null 2>&1 || true
  fi
  git -C "$dir" push -u origin "$branch":"$branch" >/dev/null 2>&1 || true
}

seed_repo() {
  local repo_dir="$1"
  log "⚙️  初始化 whoami Helm Chart（默认分支: $GIT_DEFAULT_BRANCH）"

  git -C "$repo_dir" checkout --orphan "$GIT_DEFAULT_BRANCH" >/dev/null 2>&1 || git -C "$repo_dir" checkout "$GIT_DEFAULT_BRANCH" >/dev/null 2>&1
  git -C "$repo_dir" config user.name "$GIT_COMMIT_NAME"
  git -C "$repo_dir" config user.email "$GIT_COMMIT_EMAIL"

  # 清理仓库内容（保留 .git）
  find "$repo_dir" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

  if [ ! -d "$EXAMPLE_DIR" ]; then
    log "⚠️  未找到示例目录 $EXAMPLE_DIR，无法初始化仓库"
    return 1
  fi

  cp -R "$EXAMPLE_DIR"/. "$repo_dir"/

  git -C "$repo_dir" add .
  git -C "$repo_dir" commit -m "chore: seed whoami helm chart" >/dev/null

  if ! git -C "$repo_dir" push -u origin "$GIT_DEFAULT_BRANCH" >/dev/null 2>&1; then
    log "尝试创建回退默认分支以初始化远端"
    local fallback_success=0
    # 注意: IFS 在脚本中为换行+Tab，这里使用换行分隔避免空格被视为单个词
    local fallback_branches
    fallback_branches=${GIT_FALLBACK_DEFAULT_BRANCHES:-$'main\nmaster'}
    # shellcheck disable=SC2034
    while IFS= read -r fallback; do
      if [ "$fallback" = "$GIT_DEFAULT_BRANCH" ]; then
        continue
      fi
      log "使用回退分支 $fallback 初始化远端"
      git -C "$repo_dir" branch -f "$fallback" "$GIT_DEFAULT_BRANCH" >/dev/null 2>&1 || true
      if git -C "$repo_dir" push -u origin "$fallback" >/dev/null 2>&1; then
        fallback_success=1
        log "已通过回退分支 $fallback 初始化远端"
        break
      fi
    done <<EOF
$fallback_branches
EOF
    if [ "$fallback_success" -ne 1 ]; then
      log "远端默认分支初始化未完成，跳过（不影响基础环境）"
      return 1
    fi
    # 回退分支建立后再推送期望默认分支
    git -C "$repo_dir" push origin "$GIT_DEFAULT_BRANCH":"$GIT_DEFAULT_BRANCH" >/dev/null 2>&1 || true
  fi

  # 从 CSV 派生环境分支（分支名=环境名，排除 devops）
  local csv_envs
  if [ -f "$ROOT_DIR/config/environments.csv" ]; then
    csv_envs=$(awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" | grep -v '^devops$' || true)
  fi

  for branch in $GIT_SEED_BRANCHES $csv_envs; do
    if [ "$branch" = "$GIT_DEFAULT_BRANCH" ]; then
      continue
    fi
    if git -C "$repo_dir" ls-remote --exit-code origin "$branch" >/dev/null 2>&1; then
      continue
    fi
    git -C "$repo_dir" branch -f "$branch" "$GIT_DEFAULT_BRANCH" >/dev/null 2>&1 || true
    git -C "$repo_dir" push origin "$branch":"$branch" >/dev/null 2>&1 || true
  done

  git -C "$repo_dir" remote set-head origin -a >/dev/null 2>&1 || true

  log "✓ whoami 示例仓库已初始化"
}

ensure_repo_ready() {
  local auth_url; auth_url=$(with_credentials "$GIT_REPO_URL")

  log "检查外部 Git 仓库连通性: $GIT_REPO_URL"
  if ! ls_remote "$auth_url"; then
    log "⚠️  无法访问 $GIT_REPO_URL，尝试通过 GitLab API 创建项目..."
    if ensure_gitlab_project_exists; then
      log "✓ 远端项目已存在或创建成功"
    else
      log "⚠️  远端项目创建失败，跳过仓库检查与初始化（仅影响 GitOps 演示）"
      return 0
    fi
  fi
  log "✓ 仓库访问正常"

  local tmp_dir
  tmp_dir=$(mktemp -d)

  log "克隆仓库以检测内容..."
  if ! git clone "$auth_url" "$tmp_dir/repo" >/dev/null 2>&1; then
    # fallback via 127.0.0.1 + Host header
    local host
    host=$(printf '%s' "$auth_url" | sed -E 's#^https?://([^/]+)/.*#\1#')
    if printf '%s' "$host" | grep -q '\.sslip\.io$'; then
      log "使用 127.0.0.1 + Host: $host 回退克隆"
      if ! git -c http.extraHeader="Host: $host" clone "$(echo "$auth_url" | sed -E 's#^https?://[^/]+/#http://127.0.0.1/#')" "$tmp_dir/repo" >/dev/null 2>&1; then
        log "克隆失败，跳过仓库初始化（仅影响 GitOps 演示）"
        rm -rf "$tmp_dir"
        return 0
      fi
    else
      log "克隆失败，跳过仓库初始化（仅影响 GitOps 演示）"
      rm -rf "$tmp_dir"
      return 0
    fi
  fi

  local repo_path="$tmp_dir/repo"

  if ! git -C "$repo_path" rev-parse --verify HEAD >/dev/null 2>&1; then
    seed_repo "$repo_path"
    rm -rf "$tmp_dir"
    return
  fi

  # 确保默认分支与环境分支均包含 whoami Chart
  git -C "$repo_path" config user.name "$GIT_COMMIT_NAME"
  git -C "$repo_path" config user.email "$GIT_COMMIT_EMAIL"
  local def_branch; def_branch=$(repo_default_branch "$repo_path")
  ensure_whoami_chart_in_branch "$repo_path" "$def_branch"

  local csv_envs
  if [ -f "$ROOT_DIR/config/environments.csv" ]; then
    csv_envs=$(awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" | grep -v '^devops$' || true)
  fi
  for b in $csv_envs; do
    ensure_whoami_chart_in_branch "$repo_path" "$b"
  done

  log "✓ 仓库已包含 whoami Helm Chart，已确保所有环境分支存在"

  rm -rf "$tmp_dir"
}

main() {
require_config

  if [ -n "$GIT_USERNAME" ] && [ -n "$GIT_PASSWORD" ]; then
    log "✓ 已加载外部 Git 服务凭证 ($GIT_USERNAME)"
  elif [ -n "$GIT_USERNAME" ]; then
    log "✓ 使用用户名 $GIT_USERNAME（无密码，假设凭证助手处理）"
  else
    log "⚠️  未检测到 GIT_USERNAME/GIT_PASSWORD，假定仓库允许匿名访问"
  fi

  log "Git 服务: $GIT_SERVER_URL"
  ensure_repo_ready
}

main "$@"
