#!/usr/bin/env bash
# Kindler Cluster Reconciler - 声明式集群管理
# 
# 功能：读取数据库中的期望状态，调和实际状态
# 运行方式：后台服务、cron、systemd
#
# 设计理念：
# - WebUI 只负责写入数据库（声明期望）
# - Reconciler 负责执行实际操作（调和）
# - 与预置集群创建流程完全一致（都调用 create_env.sh）

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"
. "$ROOT_DIR/scripts/lib/lib.sh"

LOG_FILE="${LOG_FILE:-/tmp/kindler_reconciler.log}"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-30}"  # 秒
# 并发度（同一时间可并行调和的集群数）。
# 注意：单个集群始终串行（通过集群级锁保证）；不同集群可并行。
RECONCILER_CONCURRENCY="${RECONCILER_CONCURRENCY:-3}"

log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $*" | tee -a "$LOG_FILE"
}

# 集群级互斥锁：确保同一集群的调和动作不并发执行（跨进程安全）
acquire_cluster_lock() {
  local name="$1"
  local _lock="/tmp/kindler_reconcile_${name}.lock"
  # 使用动态FD，便于在函数退出时释放
  exec {__lock_fd}>"${_lock}"
  if ! flock -n "${__lock_fd}"; then
    # 无法获取锁，说明已有调和在进行
    echo "LOCKED:${__lock_fd}"
    return 1
  fi
  echo "${__lock_fd}"
}

release_cluster_lock() {
  local fd="$1"
  # 释放并关闭FD
  { flock -u "$fd" 2>/dev/null || true; exec {fd}>&- 2>/dev/null || true; } || true
}

# 获取需要调和的集群列表
get_clusters_to_reconcile() {
  # 读取需要调和的集群：
  # 1. desired_state != actual_state
  # 2. actual_state 是中间状态（creating, deleting）
  # 3. 超过 5 分钟未 reconcile（健康检查）
  
  sqlite_query "
    SELECT name, provider, desired_state, actual_state, node_port, pf_port, http_port, https_port
    FROM clusters
    WHERE name != 'devops'
       AND (desired_state != actual_state
       OR actual_state IN ('creating', 'deleting')
       OR last_reconciled_at IS NULL
       OR datetime(last_reconciled_at, '+5 minutes') < datetime('now'))
    ORDER BY created_at;
  " 2>/dev/null || echo ""
}

# 更新集群状态
update_cluster_state() {
  local name="$1"
  local actual_state="$2"
  local error="${3:-}"
  
  local error_sql=""
  if [ -n "$error" ]; then
    # 转义单引号
    error=$(echo "$error" | sed "s/'/''/g")
    error_sql=", reconcile_error = '$error'"
  else
    error_sql=", reconcile_error = NULL"
  fi
  
  sqlite_transaction "
    UPDATE clusters
    SET actual_state = '$actual_state',
        last_reconciled_at = datetime('now')
        $error_sql
    WHERE name = '$name';
  " >/dev/null 2>&1
}

# 检查集群是否实际存在
check_cluster_exists() {
  local name="$1"
  local provider="$2"
  
  local ctx=""
  if [ "$provider" = "k3d" ]; then
    ctx="k3d-${name}"
  else
    ctx="kind-${name}"
  fi
  
  kubectl --context "$ctx" get nodes >/dev/null 2>&1
}

# 创建集群
reconcile_create() {
  local name="$1"
  local provider="$2"
  local node_port="${3:-30080}"
  local pf_port="${4:-19000}"
  
  log "[RECONCILE] Creating cluster: $name ($provider)"
  
  # 1. 更新状态为 creating
  update_cluster_state "$name" "creating"
  
  # 2. 执行创建脚本（与预置集群完全相同的方式）
  local create_log="/tmp/reconcile_create_${name}.log"
  if "$ROOT_DIR/scripts/create_env.sh" -n "$name" -p "$provider" \
     --node-port "$node_port" --pf-port "$pf_port" >"$create_log" 2>&1; then
    
    log "[RECONCILE] ✓ Cluster $name created successfully"
    
    # 验证集群是否真正存在
    if check_cluster_exists "$name" "$provider"; then
      update_cluster_state "$name" "running"
      log "[RECONCILE] ✓ Cluster $name verified running"
    else
      update_cluster_state "$name" "failed" "Cluster created but not accessible"
      log "[RECONCILE] ✗ Cluster $name created but not accessible"
    fi
    
  else
    local error_msg=$(tail -20 "$create_log" | tr '\n' ' ' | cut -c1-200)
    update_cluster_state "$name" "failed" "$error_msg"
    log "[RECONCILE] ✗ Cluster $name creation failed: $error_msg"
    log "[RECONCILE]   Full log: $create_log"
  fi
}

# 删除集群
reconcile_delete() {
  local name="$1"
  local provider="$2"
  
  log "[RECONCILE] Deleting cluster: $name ($provider)"
  
  # 1. 更新状态为 deleting
  update_cluster_state "$name" "deleting"
  
  # 2. 执行删除脚本
  local delete_log="/tmp/reconcile_delete_${name}.log"
  if "$ROOT_DIR/scripts/delete_env.sh" -n "$name" >"$delete_log" 2>&1; then
    
    log "[RECONCILE] ✓ Cluster $name deleted successfully"
    
    # 3. 从数据库中删除记录（desired_state = absent）
    sqlite_transaction "DELETE FROM clusters WHERE name = '$name';" >/dev/null 2>&1
    log "[RECONCILE] ✓ Cluster $name record removed from database"
    
  else
    local error_msg=$(tail -20 "$delete_log" | tr '\n' ' ' | cut -c1-200)
    update_cluster_state "$name" "failed" "$error_msg"
    log "[RECONCILE] ✗ Cluster $name deletion failed: $error_msg"
    log "[RECONCILE]   Full log: $delete_log"
  fi
}

# 验证集群健康状态
reconcile_verify() {
  local name="$1"
  local provider="$2"
  
  if check_cluster_exists "$name" "$provider"; then
    update_cluster_state "$name" "running"
    log "[RECONCILE] ✓ Cluster $name health check passed"
  else
    update_cluster_state "$name" "failed" "Cluster no longer accessible"
    log "[RECONCILE] ✗ Cluster $name health check failed"
  fi
}

# 调和单个集群
reconcile_one() {
  local name="$1"
  local provider="$2"
  local desired="$3"
  local actual="$4"
  local node_port="${5:-30080}"
  local pf_port="${6:-19000}"
  
  # 集群级锁（同名集群只允许一个动作并行执行）
  local lock_fd
  if ! lock_fd=$(acquire_cluster_lock "$name"); then
    log "[RECONCILE] ⛔ Skip $name: another action is in progress"
    return 0
  fi
  # 确保函数退出时释放锁
  trap 'release_cluster_lock "${lock_fd#LOCKED:}"' RETURN
  
  log "[RECONCILE] Reconciling $name: desired=$desired, actual=$actual"
  
  # Case 1: 期望存在，实际不存在或失败 → 创建
  if [ "$desired" = "present" ] && [ "$actual" = "unknown" -o "$actual" = "failed" ]; then
    reconcile_create "$name" "$provider" "$node_port" "$pf_port"
    
  # Case 2: 期望存在，正在创建 → 验证是否完成
  elif [ "$desired" = "present" ] && [ "$actual" = "creating" ]; then
    if check_cluster_exists "$name" "$provider"; then
      update_cluster_state "$name" "running"
      log "[RECONCILE] ✓ Cluster $name creation completed"
    else
      log "[RECONCILE] ⏳ Cluster $name still creating..."
    fi
    
  # Case 3: 期望不存在，实际存在 → 删除
  elif [ "$desired" = "absent" ] && [ "$actual" = "running" -o "$actual" = "failed" ]; then
    reconcile_delete "$name" "$provider"
    
  # Case 4: 期望存在，实际存在 → 健康检查
  elif [ "$desired" = "present" ] && [ "$actual" = "running" ]; then
    reconcile_verify "$name" "$provider"
    
  # Case 5: 期望不存在，正在删除 → 验证是否完成
  elif [ "$desired" = "absent" ] && [ "$actual" = "deleting" ]; then
    if ! check_cluster_exists "$name" "$provider"; then
      sqlite_transaction "DELETE FROM clusters WHERE name = '$name';" >/dev/null 2>&1
      log "[RECONCILE] ✓ Cluster $name deletion completed and removed from database"
    else
      log "[RECONCILE] ⏳ Cluster $name still deleting..."
    fi
    
  else
    log "[RECONCILE] ℹ Cluster $name: desired=$desired, actual=$actual (no action needed)"
  fi
}

# 单次 reconcile 循环
reconcile_once() {
  log "=========================================="
  log "[RECONCILE] Starting reconcile cycle"
  log "=========================================="
  
  # 检查数据库可用性
  if ! sqlite_is_available 2>/dev/null; then
    log "[RECONCILE] ✗ Database not available, skipping this cycle"
    return 1
  fi
  
  # 获取需要调和的集群
  local clusters
  clusters=$(get_clusters_to_reconcile)
  
  if [ -z "$clusters" ]; then
    log "[RECONCILE] ✓ No clusters need reconciliation"
    return 0
  fi
  
  local count=0
  local running=0
  local -a pids=()
  local max_conc="$RECONCILER_CONCURRENCY"

  while IFS='|' read -r name provider desired actual node_port pf_port http_port https_port; do
    [ -z "$name" ] && continue
    count=$((count + 1))

    # 后台并发执行；每个集群动作内部有集群级锁
    (
      reconcile_one "$name" "$provider" "$desired" "$actual" "$node_port" "$pf_port"
    ) &
    pids+=($!)
    running=$((running + 1))

    # 控制并发度
    if [ "$running" -ge "$max_conc" ]; then
      # 优先使用 wait -n（bash>=5），否则等待任意一个PID
      if wait -n 2>/dev/null; then
        running=$((running - 1))
      else
        # Fallback: 等待列表中的第一个PID
        local first_pid="${pids[0]}"
        if [ -n "$first_pid" ]; then
          wait "$first_pid" 2>/dev/null || true
          # 移除已完成的PID
          pids=("${pids[@]:1}")
          running=$((running - 1))
        fi
      fi
    fi
  done < <(echo "$clusters")

  # 等待剩余任务完成
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  log "[RECONCILE] Reconciled $count cluster(s) (concurrency=$RECONCILER_CONCURRENCY)"
  log "=========================================="
  echo ""
}

# 持续运行模式
reconcile_loop() {
  log "=========================================="
  log "[RECONCILE] Kindler Cluster Reconciler started"
  log "[RECONCILE] Interval: ${RECONCILE_INTERVAL}s"
  log "[RECONCILE] Database: $SQLITE_DB"
  log "[RECONCILE] Log file: $LOG_FILE"
  log "[RECONCILE] Concurrency: $RECONCILER_CONCURRENCY"
  log "=========================================="
  echo ""
  
  while true; do
    reconcile_once || true
    sleep "$RECONCILE_INTERVAL"
  done
}

# 主函数
main() {
  local mode="${1:-once}"
  
  case "$mode" in
    loop)
      reconcile_loop
      ;;
    once)
      reconcile_once
      ;;
    *)
      echo "Usage: $0 [once|loop]" >&2
      echo "  once - Run single reconcile cycle (default)" >&2
      echo "  loop - Run continuously every ${RECONCILE_INTERVAL}s" >&2
      exit 1
      ;;
  esac
}

main "$@"
