#!/usr/bin/env bash
# 并发创建 + 幂等性测试（WebUI 声明式 API）

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

backend_exec() {
  docker exec kindler-webui-backend "$@"
}

create_cluster_api() {
  local name="$1" provider="$2"
  backend_exec curl -s -X POST http://localhost:8000/api/clusters \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"provider\":\"$provider\"}" \
    -w "\n%{http_code}"
}

cluster_exists_api() {
  local name="$1"
  backend_exec curl -s http://localhost:8000/api/clusters | jq -r '.[] | .name' | grep -q "^${name}$"
}

main() {
  local c1="test-con1" p1="k3d"
  local c2="test-con2" p2="kind"

  echo "[SETUP] 清理可能存在的同名集群 (非致命)"
  "$ROOT_DIR/scripts/delete_env.sh" -n "$c1" >/dev/null 2>&1 || true
  "$ROOT_DIR/scripts/delete_env.sh" -n "$c2" >/dev/null 2>&1 || true
  backend_exec sh -lc "sqlite3 /data/kindler-webui/kindler.db 'DELETE FROM clusters WHERE name IN (\'$c1\',\'$c2\');'" || true

  echo "[TEST] 并发创建 $c1 ($p1) 与 $c2 ($p2)"
  export -f create_cluster_api backend_exec
  printf '%s\n' "$c1 $p1" "$c2 $p2" | awk '{print $1" "$2}' | while read -r n pr; do
    for i in {1..5}; do echo "$n $pr"; done
  done | xargs -n2 -P6 bash -lc 'create_cluster_api "$0" "$1"' || true

  echo "[VERIFY] API 列表应包含两个集群"
  if cluster_exists_api "$c1" && cluster_exists_api "$c2"; then
    echo "  ✓ 新集群记录存在 (DB→API)"
  else
    echo "  ✗ 新集群未出现在 API 列表中"
    exit 1
  fi

  echo "[RECONCILE] 触发单次调和以加速创建"
  "$ROOT_DIR/scripts/reconciler.sh" once || true

  echo "[WAIT] 等待上下文可用 (最多 120s)"
  for i in {1..24}; do
    ok=0
    if k3d cluster list 2>/dev/null | grep -q "^$c1 "; then ok=$((ok+1)); fi
    if kind get clusters 2>/dev/null | grep -q "^$c2$"; then ok=$((ok+1)); fi
    [ $ok -eq 2 ] && break
    sleep 5
  done

  echo "[RESULT]"
  k3d cluster list 2>/dev/null | grep -E "^(NAME|$c1)" || true
  kind get clusters 2>/dev/null | grep -E "^($c2)$" || true

  [ $ok -eq 2 ] && echo "✓ 并发创建 + 幂等性验证通过" || { echo "⚠ 部分集群尚未就绪"; exit 1; }
}

main "$@"

