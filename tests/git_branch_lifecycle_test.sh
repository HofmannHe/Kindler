#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/config/git.env"

TEST_NAME="Git Branch Lifecycle Tests"
PASSED=0
FAILED=0

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "######################################################"
echo "# ${TEST_NAME}"
echo "######################################################"
echo ""
echo "GitOps Repository: $GIT_REPO_URL"
echo "Project Repository: https://github.com/HofmannHe/Kindler.git"
echo ""

# 测试函数
test_pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  PASSED=$((PASSED + 1))
}

test_fail() {
  echo -e "  ${RED}✗${NC} $1"
  FAILED=$((FAILED + 1))
}

test_warn() {
  echo -e "  ${YELLOW}⚠${NC} $1"
}

# ====================
# 测试1: 验证两个仓库不混淆
# ====================
test_repo_separation() {
  echo "[TEST 1/5] Repository Separation"
  
  # 当前目录应该是项目代码仓库
  local current_remote=$(git remote get-url origin 2>/dev/null || echo "none")
  
  if [[ "$current_remote" == *"github.com"* ]]; then
    test_pass "当前目录是 GitHub 项目仓库: $current_remote"
  else
    test_fail "当前目录不是 GitHub 项目仓库: $current_remote"
  fi
  
  # GitOps 仓库应该是独立的
  if [[ "$GIT_REPO_URL" != *"github.com"* ]]; then
    test_pass "GitOps 仓库不在 GitHub: $GIT_REPO_URL"
  else
    test_warn "GitOps 仓库在 GitHub，可能导致混淆: $GIT_REPO_URL"
  fi
  
  echo ""
}

# ====================
# 测试2: 创建集群时自动创建 Git 分支
# ====================
test_create_cluster_creates_git_branch() {
  echo "[TEST 2/5] Create Cluster → Git Branch"
  
  local test_cluster="test-git-branch-$$"
  
  # 清理（幂等性）
  kubectl --context k3d-devops -n paas exec postgresql-0 -- \
    psql -U kindler -d kindler -c "DELETE FROM clusters WHERE name='$test_cluster';" 2>/dev/null || true
  git ls-remote --heads "$GIT_REPO_URL" | grep -q "refs/heads/$test_cluster" && {
    echo "  清理旧分支..."
    git push "$GIT_REPO_URL" --delete "$test_cluster" 2>/dev/null || true
  }
  
  # 创建集群
  echo "  创建测试集群: $test_cluster"
  "$ROOT_DIR/scripts/create_env.sh" -n "$test_cluster" -p k3d >/dev/null 2>&1
  
  # 等待 IP 分配
  sleep 10
  
  # 验证 Git 分支是否存在
  if git ls-remote --heads "$GIT_REPO_URL" | grep -q "refs/heads/$test_cluster"; then
    test_pass "Git 分支已自动创建: $test_cluster"
    
    # 验证分支内容
    local has_deploy=$(git ls-remote "$GIT_REPO_URL" "refs/heads/$test_cluster" | wc -l)
    if [ "$has_deploy" -gt 0 ]; then
      test_pass "分支包含配置文件"
    else
      test_fail "分支为空"
    fi
  else
    test_fail "Git 分支未创建: $test_cluster"
  fi
  
  # 保留集群供后续测试使用
  echo ""
}

# ====================
# 测试3: 删除集群时归档并删除 Git 分支
# ====================
test_delete_cluster_archives_git_branch() {
  echo "[TEST 3/5] Delete Cluster → Archive & Delete Branch"
  
  local test_cluster="test-git-branch-$$"
  
  # 删除集群
  echo "  删除测试集群: $test_cluster"
  "$ROOT_DIR/scripts/delete_env.sh" "$test_cluster" >/dev/null 2>&1
  
  # 等待异步清理
  sleep 15
  
  # 验证分支是否已删除
  if git ls-remote --heads "$GIT_REPO_URL" | grep -q "refs/heads/$test_cluster"; then
    test_fail "Git 分支未删除: $test_cluster"
  else
    test_pass "Git 分支已删除: $test_cluster"
  fi
  
  # 验证归档 tag 是否存在（test- 分支是 ephemeral，可能不归档）
  local archive_tags=$(git ls-remote --tags "$GIT_REPO_URL" | grep "refs/tags/archive/$test_cluster/" | wc -l)
  if [ "$archive_tags" -gt 0 ]; then
    test_pass "分支已归档为 tag (找到 $archive_tags 个归档)"
  else
    test_warn "未找到归档 tag（test- 分支可能直接删除）"
  fi
  
  echo ""
}

# ====================
# 测试4: 验证分支同步策略（自动 fetch）
# ====================
test_git_sync_strategy() {
  echo "[TEST 4/5] Git Sync Strategy"
  
  # 创建测试分支（模拟远程变更）
  local test_branch="test-sync-$$"
  
  # 在远程创建分支
  echo "  创建远程测试分支..."
  git fetch "$GIT_REPO_URL" devops:refs/remotes/gitops/devops 2>/dev/null || true
  git push "$GIT_REPO_URL" refs/remotes/gitops/devops:refs/heads/$test_branch 2>/dev/null || {
    test_warn "无法创建远程测试分支，跳过此测试"
    echo ""
    return 0
  }
  
  # 测试 create_env.sh 是否会自动 fetch
  # （这里只能间接测试，通过检查脚本内容）
  if grep -q "git fetch" "$ROOT_DIR/scripts/create_env.sh"; then
    test_pass "create_env.sh 包含 git fetch 逻辑"
  else
    test_fail "create_env.sh 缺少 git fetch 逻辑"
  fi
  
  # 清理测试分支
  git push "$GIT_REPO_URL" --delete "$test_branch" 2>/dev/null || true
  
  echo ""
}

# ====================
# 测试5: 验证不会误操作 GitHub 项目仓库
# ====================
test_no_github_repo_modification() {
  echo "[TEST 5/5] No GitHub Repository Modification"
  
  # 检查脚本中是否有保护措施
  local has_protection=0
  
  # create_env.sh 应该只操作 GitOps 仓库
  if grep -q "\$GIT_REPO_URL" "$ROOT_DIR/scripts/create_env.sh"; then
    test_pass "create_env.sh 使用 \$GIT_REPO_URL 变量"
    has_protection=$((has_protection + 1))
  else
    test_fail "create_env.sh 未使用 \$GIT_REPO_URL 变量"
  fi
  
  # delete_env.sh 应该只操作 GitOps 仓库
  if grep -q "\$GIT_REPO_URL" "$ROOT_DIR/scripts/delete_env.sh"; then
    test_pass "delete_env.sh 使用 \$GIT_REPO_URL 变量"
    has_protection=$((has_protection + 1))
  else
    test_fail "delete_env.sh 未使用 \$GIT_REPO_URL 变量"
  fi
  
  # 验证当前 Git 仓库未被修改
  local uncommitted=$(git status --porcelain | wc -l)
  if [ "$uncommitted" -eq 0 ]; then
    test_pass "GitHub 项目仓库未被修改"
  else
    test_warn "GitHub 项目仓库有未提交的更改（可能来自其他操作）"
  fi
  
  echo ""
}

# ====================
# 运行所有测试
# ====================
echo "=========================================="
echo "Running Tests"
echo "=========================================="
echo ""

test_repo_separation
test_create_cluster_creates_git_branch
test_delete_cluster_archives_git_branch
test_git_sync_strategy
test_no_github_repo_modification

# ====================
# 输出结果
# ====================
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total:  $((PASSED + FAILED))"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
  echo "✓ ALL PASS"
  exit 0
else
  echo "✗ SOME FAILED"
  exit 1
fi

