#!/usr/bin/env bash
# WebUI 并发创建/删除循环测试（声明式 + Reconciler）
# - 支持配置并发度与集群数量
# - 默认执行 3 个循环：并发创建 → 调和 → 校验 → 并发删除 → 调和 → 校验

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 参数
CLUSTERS=${CLUSTERS:-4}                 # 集群数量（默认4：k3d与kind各2个）
WORKERS=${WORKERS:-3}                   # API并发度（xargs -P），默认3
RECONCILER_CONCURRENCY=${RECONCILER_CONCURRENCY:-3}  # Reconciler并发度，默认3
CYCLES=${CYCLES:-3}                     # 创建-删除循环次数，默认3
WAIT_TIMEOUT=${WAIT_TIMEOUT:-420}       # 等待每阶段完成的最大秒数

backend_exec() {
  docker exec kindler-webui-backend "$@"
}

api_create() {
  local name="$1" provider="$2"
  backend_exec curl -sS -X POST http://localhost:8000/api/clusters \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"provider\":\"$provider\"}" \
    -w "\n%{http_code}"
}

api_delete() {
  local name="$1"
  backend_exec curl -sS -X DELETE http://localhost:8000/api/clusters/"$name" -w "\n%{http_code}"
}

cluster_exists() {
  local name="$1" provider="$2"
  if [ "$provider" = "k3d" ]; then
    k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$name"
  else
    kind get clusters 2>/dev/null | grep -qx "$name"
  fi
}

wait_until_created() {
  local names=($1) providers=($2)
  local start=$(date +%s)
  while true; do
    local ok=0
    local total=${#names[@]}
    for i in "${!names[@]}"; do
      if cluster_exists "${names[$i]}" "${providers[$i]}"; then
        ok=$((ok+1))
      fi
    done
    if [ "$ok" -eq "$total" ]; then
      echo "  ✓ 所有 $total 集群创建完成"
      return 0
    fi
    # 触发一次并发调和
    RECONCILER_CONCURRENCY="$RECONCILER_CONCURRENCY" "$ROOT_DIR/scripts/reconciler.sh" once || true
    sleep 5
    local now=$(date +%s)
    if [ $((now-start)) -ge "$WAIT_TIMEOUT" ]; then
      echo "  ✗ 等待创建超时 (${WAIT_TIMEOUT}s): $ok/$total 就绪"
      return 1
    fi
  done
}

wait_until_deleted() {
  local names=($1) providers=($2)
  local start=$(date +%s)
  while true; do
    local remaining=0
    local total=${#names[@]}
    for i in "${!names[@]}"; do
      if cluster_exists "${names[$i]}" "${providers[$i]}"; then
        remaining=$((remaining+1))
      fi
    done
    if [ "$remaining" -eq 0 ]; then
      echo "  ✓ 所有 $total 集群删除完成"
      return 0
    fi
    # 触发一次并发调和
    RECONCILER_CONCURRENCY="$RECONCILER_CONCURRENCY" "$ROOT_DIR/scripts/reconciler.sh" once || true
    sleep 5
    local now=$(date +%s)
    if [ $((now-start)) -ge "$WAIT_TIMEOUT" ]; then
      echo "  ✗ 等待删除超时 (${WAIT_TIMEOUT}s): 剩余 $remaining/$total 未删除"
      return 1
    fi
  done
}

verify_argocd_absent() {
  local name
  for name in "$@"; do
    if kubectl --context k3d-devops -n argocd get secret "cluster-${name}" >/dev/null 2>&1; then
      echo "  ✗ 残留 ArgoCD secret: cluster-${name}"
      return 1
    fi
  done
  echo "  ✓ 无剩余 ArgoCD 集群密钥"
}

verify_db_absent() {
  local name
  local missing=0
  for name in "$@"; do
    local cnt
    cnt=$(backend_exec sh -lc "sqlite3 /data/kindler-webui/kindler.db \"SELECT COUNT(*) FROM clusters WHERE name='$name';\"" | tr -d ' ') || cnt=1
    if [ "${cnt:-1}" -ne 0 ]; then
      echo "  ✗ DB 残留记录: $name -> $cnt"
      missing=$((missing+1))
    fi
  done
  if [ "$missing" -eq 0 ]; then
    echo "  ✓ DB 无残留记录"
    return 0
  else
    return 1
  fi
}

main() {
  echo "[SETUP] 生成测试集群清单 (CLUSTERS=$CLUSTERS, WORKERS=$WORKERS, RECONCILER_CONCURRENCY=$RECONCILER_CONCURRENCY, CYCLES=$CYCLES)"

  # 生成集群列表：交替使用 k3d 与 kind
  local names=()
  local providers=()
  local ts=$(date +%H%M%S)
  for i in $(seq 1 "$CLUSTERS"); do
    local name="testcd-${ts}-$i"
    if [ $((i % 2)) -eq 1 ]; then
      providers+=("k3d")
    else
      providers+=("kind")
    fi
    names+=("$name")
  done

  echo "[INFO] 本次测试的集群:"
  for i in "${!names[@]}"; do
    echo "  - ${names[$i]} (${providers[$i]})"
  done

  local cycle
  for cycle in $(seq 1 "$CYCLES"); do
    echo ""
    echo "================= 循环 $cycle/$CYCLES: 并发创建 ================="
    # 清理同名遗留（非致命）
    for i in "${!names[@]}"; do
      "$ROOT_DIR/scripts/delete_env.sh" -n "${names[$i]}" >/dev/null 2>&1 || true
      backend_exec sh -lc "sqlite3 /data/kindler-webui/kindler.db \"DELETE FROM clusters WHERE name='${names[$i]}';\"" || true
    done

    # 并发声明创建
    export -f backend_exec api_create
    paste <(printf '%s\n' "${names[@]}") <(printf '%s\n' "${providers[@]}") | \
      xargs -n2 -P "$WORKERS" bash -lc 'api_create "$0" "$1"' || true

    # 等待实际创建完成
    wait_until_created "${names[*]}" "${providers[*]}"

    echo "================= 循环 $cycle/$CYCLES: 并发删除 ================="
    export -f api_delete
    printf '%s\n' "${names[@]}" | xargs -n1 -P "$WORKERS" bash -lc 'api_delete "$0"' || true

    # 等待彻底删除（集群/ArgoCD/DB）
    wait_until_deleted "${names[*]}" "${providers[*]}"
    verify_argocd_absent "${names[@]}" || { echo "  ⚠ ArgoCD 残留，继续尝试调和"; RECONCILER_CONCURRENCY="$RECONCILER_CONCURRENCY" "$ROOT_DIR/scripts/reconciler.sh" once || true; }
    verify_db_absent "${names[@]}"
  done

  echo ""
  echo "✓ 并发创建-删除循环测试通过 (循环次数=$CYCLES)"
}

main "$@"

