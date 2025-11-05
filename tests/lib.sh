#!/usr/bin/env bash
# 测试工具库
# 提供断言函数、计数器和报告生成

# 测试计数器
total_tests=0
passed_tests=0
failed_tests=0

# 断言：相等
assert_equals() {
  local expected="$1" actual="$2" description="$3"
  total_tests=$((total_tests + 1))
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $description"
    passed_tests=$((passed_tests + 1))
    return 0
  else
    echo "  ✗ $description"
    echo "    Expected: $expected"
    echo "    Actual: $actual"
    failed_tests=$((failed_tests + 1))
    return 1
  fi
}

# 断言：包含
assert_contains() {
  local haystack="$1" needle="$2" description="$3"
  total_tests=$((total_tests + 1))
  if echo "$haystack" | grep -q "$needle"; then
    echo "  ✓ $description"
    passed_tests=$((passed_tests + 1))
    return 0
  else
    echo "  ✗ $description"
    echo "    Expected to contain: $needle"
    echo "    Actual: $(echo "$haystack" | head -1)"
    failed_tests=$((failed_tests + 1))
    return 1
  fi
}

# 断言：不包含
assert_not_contains() {
  local haystack="$1" needle="$2" description="$3"
  total_tests=$((total_tests + 1))
  if ! echo "$haystack" | grep -q "$needle"; then
    echo "  ✓ $description"
    passed_tests=$((passed_tests + 1))
    return 0
  else
    echo "  ✗ $description"
    echo "    Expected NOT to contain: $needle"
    failed_tests=$((failed_tests + 1))
    return 1
  fi
}

# 断言：HTTP 状态码
assert_http_status() {
  local expected="$1" url="$2" host="$3" description="$4"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -H "Host: $host" "$url" 2>/dev/null || echo "000")
  assert_equals "$expected" "$status" "$description"
}

# 断言：命令成功
assert_success() {
  local description="$1"
  shift
  total_tests=$((total_tests + 1))
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $description"
    passed_tests=$((passed_tests + 1))
    return 0
  else
    echo "  ✗ $description"
    echo "    Command failed: $*"
    failed_tests=$((failed_tests + 1))
    return 1
  fi
}

# 断言：大于
assert_greater_than() {
  local threshold="$1" actual="$2" description="$3"
  total_tests=$((total_tests + 1))
  if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
    echo "  ✓ $description"
    passed_tests=$((passed_tests + 1))
    return 0
  else
    echo "  ✗ $description"
    echo "    Expected > $threshold, got: $actual"
    failed_tests=$((failed_tests + 1))
    return 1
  fi
}

# 打印测试摘要
print_summary() {
  echo ""
  echo "=========================================="
  echo "Test Summary"
  echo "=========================================="
  echo "Total:  $total_tests"
  echo "Passed: $passed_tests"
  echo "Failed: $failed_tests"
  if [ $failed_tests -eq 0 ]; then
    echo "Status: ✓ ALL PASS"
    return 0
  else
    echo "Status: ✗ SOME FAILED"
    return 1
  fi
}

