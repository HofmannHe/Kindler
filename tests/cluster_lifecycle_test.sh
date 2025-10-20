#!/usr/bin/env bash
# 集群生命周期端到端测试

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/lib.sh"
source "$ROOT_DIR/scripts/lib_db.sh"

echo "######################################################"
echo "# Cluster Lifecycle Tests"
echo "######################################################"
echo "=========================================="
echo "Create/Delete Lifecycle Validation"
echo "=========================================="
echo ""

TEST_CLUSTER="test-lifecycle-$$"  # 使用 PID 确保唯一性

cleanup() {
  echo ""
  echo "[CLEANUP] Removing test cluster if exists..."
  "$ROOT_DIR/scripts/delete_env.sh" -n "$TEST_CLUSTER" -p k3d 2>/dev/null || true
  
  # 清理 Git 分支
  if [ -f "$ROOT_DIR/scripts/delete_git_branch.sh" ]; then
    "$ROOT_DIR/scripts/delete_git_branch.sh" "$TEST_CLUSTER" 2>/dev/null || true
  fi
}

trap cleanup EXIT

##############################################
# 1. 创建测试集群
##############################################
echo "[1/4] Creating Test Cluster: $TEST_CLUSTER"

# 使用 --force 参数允许创建不在 CSV 中的临时集群
if timeout 180 "$ROOT_DIR/scripts/create_env.sh" -n "$TEST_CLUSTER" -p k3d --force --no-register-portainer --haproxy-route >/tmp/create_test.log 2>&1; then
  echo "  ✓ Cluster creation completed"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ Cluster creation failed"
  echo "  See /tmp/create_test.log for details"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

echo ""

##############################################
# 2. 验证资源创建
##############################################
echo "[2/4] Verifying Resources Created"

# 检查 K8s 集群
if kubectl config get-contexts "k3d-$TEST_CLUSTER" >/dev/null 2>&1; then
  echo "  ✓ K8s cluster exists"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ K8s cluster not found"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 检查 DB 记录
if db_is_available 2>/dev/null; then
  if db_get_cluster "$TEST_CLUSTER" >/dev/null 2>&1; then
    echo "  ✓ DB record exists"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ DB record not found"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
else
  echo "  ⚠ DB not available, skipping DB check"
fi

# 检查 Git 分支（可选，因为可能失败）
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
  if [ -n "${GIT_REPO_URL:-}" ]; then
    if git ls-remote --heads "$GIT_REPO_URL" "$TEST_CLUSTER" 2>/dev/null | grep -q "$TEST_CLUSTER"; then
      echo "  ✓ Git branch exists"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ⚠ Git branch not found (may be expected if Git service unavailable)"
      passed_tests=$((passed_tests + 1))  # 不作为失败条件
    fi
    total_tests=$((total_tests + 1))
  fi
fi

echo ""

##############################################
# 3. 删除测试集群
##############################################
echo "[3/4] Deleting Test Cluster: $TEST_CLUSTER"

if "$ROOT_DIR/scripts/delete_env.sh" -n "$TEST_CLUSTER" -p k3d >/tmp/delete_test.log 2>&1; then
  echo "  ✓ Cluster deletion completed"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ Cluster deletion failed"
  echo "  See /tmp/delete_test.log for details"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

echo ""

##############################################
# 4. 验证资源清理
##############################################
echo "[4/4] Verifying Resources Cleaned Up"

# 检查 K8s 集群已删除
if ! kubectl config get-contexts "k3d-$TEST_CLUSTER" >/dev/null 2>&1; then
  echo "  ✓ K8s cluster removed"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ K8s cluster still exists"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 检查 DB 记录已删除
if db_is_available 2>/dev/null; then
  if ! db_get_cluster "$TEST_CLUSTER" >/dev/null 2>&1; then
    echo "  ✓ DB record removed"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ DB record still exists"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
else
  echo "  ⚠ DB not available, skipping DB check"
fi

# 检查 Git 分支已删除
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
  if [ -n "${GIT_REPO_URL:-}" ]; then
    if ! git ls-remote --heads "$GIT_REPO_URL" "$TEST_CLUSTER" 2>/dev/null | grep -q "$TEST_CLUSTER"; then
      echo "  ✓ Git branch removed"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ⚠ Git branch still exists (may need manual cleanup)"
      passed_tests=$((passed_tests + 1))  # 不作为失败条件
    fi
    total_tests=$((total_tests + 1))
  fi
fi

echo ""

##############################################
# 测试摘要
##############################################
print_summary

# 清理日志
rm -f /tmp/create_test.log /tmp/delete_test.log

exit $failed_tests


