#!/usr/bin/env bash
# WebUI集群可见性测试 - 验证WebUI能看到所有集群

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/lib.sh"

echo "=========================================="
echo "WebUI Cluster Visibility Test"
echo "=========================================="
echo ""

# 1. 检查WebUI后端运行状态
echo "[1/4] Checking WebUI backend status"
if ! docker ps | grep -q "kindler-webui-backend"; then
  echo "  ✗ WebUI backend not running"
  exit 1
fi
echo "  ✓ WebUI backend is running"
passed_tests=$((passed_tests + 1))
total_tests=$((total_tests + 1))

# 2. 检查PostgreSQL连接
echo ""
echo "[2/4] Testing PostgreSQL connection from WebUI"
if timeout 10 docker exec kindler-webui-backend curl -s http://localhost:8000/api/health 2>/dev/null | grep -q "healthy"; then
  echo "  ✓ WebUI health check passed"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ WebUI health check failed"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 3. 检查数据库中的集群
echo ""
echo "[3/4] Checking clusters in database"
db_clusters=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
  psql -U kindler -d kindler -t -c "SELECT name FROM clusters ORDER BY name" 2>/dev/null | \
  tr -d ' ' | grep -v '^$' || echo "")

if [ -z "$db_clusters" ]; then
  echo "  ✗ No clusters found in database"
  failed_tests=$((failed_tests + 1))
else
  db_count=$(echo "$db_clusters" | wc -l)
  echo "  ✓ Found $db_count cluster(s) in database:"
  echo "$db_clusters" | sed 's/^/    - /'
  passed_tests=$((passed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 4. 检查WebUI API返回的集群
echo ""
echo "[4/4] Checking clusters visible in WebUI API"
api_response=$(timeout 10 docker exec kindler-webui-backend curl -s http://localhost:8000/api/clusters 2>/dev/null || echo "[]")
api_count=$(echo "$api_response" | jq '. | length' 2>/dev/null || echo "0")

if [ "$api_count" -eq 0 ]; then
  echo "  ✗ WebUI API返回0个集群"
  echo "  DB中有: $(echo "$db_clusters" | wc -l)个集群"
  echo "  诊断信息:"
  echo "  - 检查WebUI后端日志: docker logs kindler-webui-backend 2>&1 | tail -50"
  echo "  - 检查PostgreSQL连接: docker exec kindler-webui-backend env | grep PG_"
  echo "  - 测试连接: docker exec kindler-webui-backend nc -zv haproxy-gw 5432"
  failed_tests=$((failed_tests + 1))
else
  echo "  ✓ WebUI API返回 $api_count 个集群:"
  echo "$api_response" | jq -r '.[] | "    - \(.name) (\(.provider))"' 2>/dev/null || echo "$api_response"
  
  # 验证数量是否匹配
  if [ "$api_count" -eq "$db_count" ]; then
    echo "  ✓ WebUI集群数量与DB一致"

# 5. 验证status字段正确性
echo ""
echo "" && echo "[5/5] Verifying status field accuracy"
wrong_status=0
for cluster_json in $(echo "$api_response" | jq -c ".[]" 2>/dev/null); do
  cluster_name=$(echo "$cluster_json" | jq -r ".name")
  cluster_status=$(echo "$cluster_json" | jq -r ".status")
  
  # 检查status字段（应该是running，因为DB中有记录即表示配置存在）
  if [ "$cluster_status" != "running" ]; then
  echo "  ✗ Cluster $cluster_name status is "$cluster_status", expected "running""
    wrong_status=$((wrong_status + 1))
  fi
done

if [ $wrong_status -eq 0 ]; then
  echo "  ✓ All clusters show correct status (running)"
else
  echo "  ✗ $wrong_status cluster(s) with wrong status"
fi
total_tests=$((total_tests + 1))
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ WebUI集群数量($api_count)与DB($db_count)不一致"
    failed_tests=$((failed_tests + 1))
  fi
fi
total_tests=$((total_tests + 1))

# 测试结果汇总
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total:  $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $failed_tests"

if [ $failed_tests -eq 0 ]; then
  echo "Status: ✓ ALL PASS"
  exit 0
else
  echo "Status: ✗ SOME FAILURES"
  exit 1
fi

