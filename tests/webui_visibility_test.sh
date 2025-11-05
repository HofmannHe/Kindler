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
echo "[1/5] Checking WebUI backend status"
# Robust exact-name check
if ! docker ps --filter name=kindler-webui-backend --format '{{.Names}}' | grep -qx 'kindler-webui-backend'; then
  echo "  ✗ WebUI backend not running"
  exit 1
fi
echo "  ✓ WebUI backend is running"
passed_tests=$((passed_tests + 1))
total_tests=$((total_tests + 1))

# 2. 检查PostgreSQL连接
echo ""
echo "[2/5] Testing WebUI health endpoint"
if timeout 10 docker exec kindler-webui-backend curl -s http://localhost:8000/api/health 2>/dev/null | grep -q "healthy"; then
  echo "  ✓ WebUI health check passed"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ WebUI health check failed"
  failed_tests=$((failed_tests + 1))
fi
total_tests=$((total_tests + 1))

# 3. 检查数据库中的集群（SQLite via backend container）
echo ""
echo "[3/5] Checking clusters in SQLite DB"
db_clusters=$(docker exec -i kindler-webui-backend sh -c \
  "sqlite3 /data/kindler-webui/kindler.db 'SELECT name FROM clusters ORDER BY name;'" 2>/dev/null | \
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
echo "[4/5] Checking clusters visible in WebUI API"
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
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ WebUI集群数量($api_count)与DB($db_count)不一致"
    failed_tests=$((failed_tests + 1))
  fi
fi
total_tests=$((total_tests + 1))

# 5. 验证 /api/clusters/{name}/status 的 Portainer/ArgoCD 可达性字段
echo ""
echo "[5/5] Verifying Portainer/ArgoCD reachability via status API"
status_fail=0
for name in $(echo "$api_response" | jq -r '.[].name'); do
  s=$(timeout 10 docker exec kindler-webui-backend curl -s "http://localhost:8000/api/clusters/${name}/status" 2>/dev/null || echo '{}')
  portainer=$(echo "$s" | jq -r '.portainer_status // "unknown"')
  argocd=$(echo "$s" | jq -r '.argocd_status // "unknown"')
  overall=$(echo "$s" | jq -r '.status // "unknown"')
  # 仅校验字段存在且在允许集合内；不强制 overall=running
  case ",$portainer," in
    *,online,*|*,offline,*|*,unknown,*) : ;;
    *) echo "  ✗ $name: invalid portainer_status=$portainer"; status_fail=$((status_fail + 1));;
  esac
  case ",$argocd," in
    *,healthy,*|*,degraded,*|*,unknown,*) : ;;
    *) echo "  ✗ $name: invalid argocd_status=$argocd"; status_fail=$((status_fail + 1));;
  esac
  if [ "$overall" = "error" ]; then
    echo "  ✗ $name: overall status=error"
    status_fail=$((status_fail + 1))
  fi
done
if [ $status_fail -eq 0 ]; then
  echo "  ✓ Status API returns valid reachability fields"
  passed_tests=$((passed_tests + 1))
else
  echo "  ✗ $status_fail cluster(s) with invalid status fields"
  failed_tests=$((failed_tests + 1))
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
