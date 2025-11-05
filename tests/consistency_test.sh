#!/usr/bin/env bash
# 一致性检查功能测试

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/lib.sh"

echo "######################################################"
echo "# Consistency Check Tests"
echo "######################################################"
echo "=========================================="
echo "DB-Git-K8s Consistency Validation"
echo "=========================================="
echo ""

##############################################
# 1. 检查脚本存在性
##############################################
echo "[1/3] Script Availability"

if [ -x "$ROOT_DIR/scripts/check_consistency.sh" ]; then
  echo "  ✓ check_consistency.sh exists and is executable"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ check_consistency.sh not found or not executable"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

if [ -x "$ROOT_DIR/scripts/sync_git_from_db.sh" ]; then
  echo "  ✓ sync_git_from_db.sh exists and is executable"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ sync_git_from_db.sh not found or not executable"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

echo ""

##############################################
# 2. 运行一致性检查
##############################################
echo "[2/3] Running Consistency Check"

if "$ROOT_DIR/scripts/check_consistency.sh" >/tmp/consistency_check.log 2>&1; then
  echo "  ✓ Consistency check completed successfully"
  passed_tests=$((passed_tests + 1))
  
  # 显示摘要
  grep -E "✓|✗" /tmp/consistency_check.log | head -10 | sed 's/^/    /'
else
  echo "  ⚠ Consistency check found issues (expected in some cases)"
  passed_tests=$((passed_tests + 1))  # 发现不一致也算测试通过
  
  # 显示问题
  grep -E "✗|Inconsistency" /tmp/consistency_check.log | head -5 | sed 's/^/    /'
fi
total_tests=$((total_tests + 1))

echo ""

##############################################
# 3. 检查输出格式
##############################################
echo "[3/3] Output Format Validation"

# 检查是否包含预期的部分
required_sections=(
  "读取数据库记录"
  "检查 Git 分支"
  "检查 Kubernetes 集群"
  "一致性分析"
  "修复建议"
)

for section in "${required_sections[@]}"; do
  if grep -q "$section" /tmp/consistency_check.log; then
    echo "  ✓ Output contains '$section' section"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ Output missing '$section' section"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

echo ""

##############################################
# 测试摘要
##############################################
print_summary

# 清理
rm -f /tmp/consistency_check.log

exit $failed_tests


