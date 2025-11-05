#!/usr/bin/env bash
# 修复所有 Git 分支的 whoami ingress host 配置
# 移除域名中的 provider 后缀

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo "  修复 Git 分支域名格式"
echo "=========================================="
echo

# 加载 Git 配置
GIT_ENV_FILE="$ROOT_DIR/config/git.env"
if [ ! -f "$GIT_ENV_FILE" ]; then
  echo "❌ Git configuration not found: $GIT_ENV_FILE"
  exit 1
fi

set -a
source "$GIT_ENV_FILE"
set +a

if [ -z "$GIT_REPO_URL" ]; then
  echo "❌ GIT_REPO_URL not configured"
  exit 1
fi

echo "✓ Git repository: $GIT_REPO_URL"
echo

# 获取所有业务集群
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "❌ No business clusters found in environments.csv"
  exit 1
fi

# 临时工作目录
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

cd "$TMPDIR"

# Clone 仓库
echo "[1/3] Cloning repository..."
if [ -n "$GIT_PASSWORD" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
  git clone "$GIT_REPO_URL_AUTH" repo 2>&1 | grep -v "password" || true
else
  git clone "$GIT_REPO_URL" repo
fi

cd repo
git config user.name "Kindler Automation"
git config user.email "kindler@local"

echo
echo "[2/3] Updating all branches..."
fixed_count=0
failed_count=0

for cluster in $clusters; do
  echo
  echo "Processing: $cluster"
  
  # 提取环境名（去掉 -k3d/-kind 后缀）
  env_name="${cluster%-k3d}"
  env_name="${env_name%-kind}"
  
  # 确定 ingress class
  if echo "$cluster" | grep -q "k3d"; then
    ingress_class="traefik"
  else
    ingress_class="nginx"
  fi
  
  # 检查分支是否存在
  if ! git ls-remote --heads origin "$cluster" | grep -q "$cluster"; then
    echo "  ⚠ Branch '$cluster' does not exist, skipping"
    continue
  fi
  
  # 切换到分支
  git checkout "$cluster" 2>/dev/null || git checkout -b "$cluster" "origin/$cluster"
  
  # 检查 values.yaml 是否存在
  if [ ! -f "deploy/values.yaml" ]; then
    echo "  ⚠ values.yaml not found, skipping"
    continue
  fi
  
  # 读取当前的 host
  current_host=$(grep "host:" deploy/values.yaml | awk '{print $2}' || echo "")
  expected_host="whoami.$env_name.192.168.51.30.sslip.io"
  
  if [ "$current_host" = "$expected_host" ]; then
    echo "  ✓ Already correct: $current_host"
    continue
  fi
  
  echo "  Fixing: $current_host -> $expected_host"
  
  # 更新 values.yaml
  cat > deploy/values.yaml <<VALUESEOF
# whoami Helm Chart values for $cluster (env: $env_name)
replicaCount: 1

image:
  repository: traefik/whoami
  tag: v1.10.2
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  className: $ingress_class
  host: whoami.$env_name.192.168.51.30.sslip.io
  path: /
  pathType: Prefix

resources:
  limits:
    cpu: 100m
    memory: 64Mi
  requests:
    cpu: 50m
    memory: 32Mi
VALUESEOF
  
  # 提交更改
  if git diff --quiet; then
    echo "  ⚠ No changes detected"
  else
    git add deploy/values.yaml
    git commit -m "fix: remove provider from whoami ingress host ($current_host -> $expected_host)"
    
    # 推送到远程
    if git push origin "$cluster" 2>&1 | grep -v "password"; then
      echo "  ✓ Fixed and pushed: $cluster"
      fixed_count=$((fixed_count + 1))
    else
      echo "  ✗ Failed to push: $cluster"
      failed_count=$((failed_count + 1))
    fi
  fi
done

echo
echo "[3/3] Summary"
echo "  Fixed: $fixed_count"
echo "  Failed: $failed_count"
echo

if [ $failed_count -eq 0 ]; then
  echo "✅ All branches fixed successfully!"
  exit 0
else
  echo "⚠ Some branches failed to update"
  exit 1
fi

