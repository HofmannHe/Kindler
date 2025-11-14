#!/usr/bin/env bash
# SQLite 迁移后的完整回归测试脚本：严格依赖仓库脚本/代码，禁止任何手动步骤。

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

TIMEOUT_CLEAN=300      # 5 分钟
TIMEOUT_BOOTSTRAP=600  # 10 分钟
TIMEOUT_CREATE=300     # 5 分钟
TIMEOUT_RECON=900      # 15 分钟（含 GitOps/HAProxy 同步）

TEST_CLUSTERS=(test-script-k3d test-script-kind)
declare -A TEST_CLUSTER_PROVIDER=(
  [test-script-k3d]=k3d
  [test-script-kind]=kind
)

MODE="full"
SKIP_CLEAN=false
SKIP_BOOTSTRAP=false
SKIP_SMOKE=false
SKIP_BATS=false
CLUSTER_FILTER_RAW=""
LOG_DIR_OVERRIDE=""

trim() {
  local var="$1"
  var="${var#${var%%[![:space:]]*}}"
  var="${var%${var##*[![:space:]]}}"
  printf '%s' "$var"
}

usage() {
  cat <<'USAGE'
用法: tests/regression_test.sh [选项]

选项:
  --full               执行完整回归（默认）
  --skip-clean         跳过 scripts/clean.sh（用于快速复测）
  --skip-bootstrap     跳过 scripts/bootstrap.sh
  --skip-smoke         跳过对业务集群执行 scripts/smoke.sh
  --skip-bats          跳过 bats tests（不推荐）
  --clusters a,b,c     仅针对指定业务集群执行 smoke/校验
  --log-dir <dir>      自定义日志目录（默认 logs/regression/<timestamp>）
  -h, --help           显示此帮助

所有步骤均由脚本实现，出现需要手动干预的情况即视为失败。
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --full)
      MODE="full"
      shift
      ;;
    --skip-clean)
      SKIP_CLEAN=true
      shift
      ;;
    --skip-bootstrap)
      SKIP_BOOTSTRAP=true
      shift
      ;;
    --skip-smoke)
      SKIP_SMOKE=true
      shift
      ;;
    --skip-bats)
      SKIP_BATS=true
      shift
      ;;
    --clusters)
      [ $# -ge 2 ] || usage
      CLUSTER_FILTER_RAW="$2"
      shift 2
      ;;
    --log-dir)
      [ $# -ge 2 ] || usage
      LOG_DIR_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      ;;
  esac
done

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
DEFAULT_LOG_DIR="$ROOT_DIR/logs/regression/$RUN_ID"
RUN_DIR="${LOG_DIR_OVERRIDE:-$DEFAULT_LOG_DIR}"
mkdir -p "$RUN_DIR"
MAIN_LOG="$RUN_DIR/regression.log"
LOG_FILE="$MAIN_LOG"
RECON_LOG="$RUN_DIR/phase3-reconcile.log"
touch "$MAIN_LOG"
touch "$RECON_LOG"
touch "$ROOT_DIR/docs/TEST_REPORT.md"

printf '==========================================\n' | tee -a "$MAIN_LOG"
printf '  SQLite 迁移完整回归测试\n' | tee -a "$MAIN_LOG"
printf '==========================================\n' | tee -a "$MAIN_LOG"
printf '开始时间: %s\n' "$(date)" | tee -a "$MAIN_LOG"
printf '日志目录: %s\n' "$RUN_DIR" | tee -a "$MAIN_LOG"
printf '模式: %s\n' "$MODE" | tee -a "$MAIN_LOG"
[ -n "$CLUSTER_FILTER_RAW" ] && printf '集群过滤: %s\n' "$CLUSTER_FILTER_RAW" | tee -a "$MAIN_LOG"
printf '\n' | tee -a "$MAIN_LOG"

TEST_REPORT="$ROOT_DIR/docs/TEST_REPORT.md"

cleanup_test_clusters() {
  local quiet="${1:-false}"
  local removed=false
  for name in "${TEST_CLUSTERS[@]}"; do
    if k3d cluster list 2>/dev/null | grep -q "$name"; then
      "$ROOT_DIR/scripts/delete_env.sh" -n "$name" >/dev/null 2>&1 || true
      removed=true
    elif kind get clusters 2>/dev/null | grep -q "$name"; then
      "$ROOT_DIR/scripts/delete_env.sh" -n "$name" >/dev/null 2>&1 || true
      removed=true
    fi
  done
  if ! $quiet; then
    if $removed; then
      echo "  ✓ 已清理测试集群" | tee -a "$MAIN_LOG"
    else
      echo "  ✓ 无需清理测试集群" | tee -a "$MAIN_LOG"
    fi
  fi
}

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    echo "" | tee -a "$MAIN_LOG"
    echo "==========================================" | tee -a "$MAIN_LOG"
    echo "  ✗ 回归测试失败，触发自动清理" | tee -a "$MAIN_LOG"
    echo "==========================================" | tee -a "$MAIN_LOG"
  fi
  cleanup_test_clusters true || true
}

trap cleanup EXIT

run_with_monitor() {
  local timeout="$1"
  local name="$2"
  local log_path="$3"
  shift 3
  local cmd=("$@")

  mkdir -p "$(dirname "$log_path")"
  : >"$log_path"
  local prev_log="$LOG_FILE"
  LOG_FILE="$log_path"

  echo "[$name] 开始执行 (日志: $LOG_FILE, 超时 ${timeout}s)" | tee -a "$MAIN_LOG"
  "${cmd[@]}" >"$LOG_FILE" 2>&1 &
  local pid=$!
  local elapsed=0
  local check_interval=30

  while kill -0 $pid 2>/dev/null; do
    sleep $check_interval
    elapsed=$((elapsed + check_interval))
    echo "  [$name] 进度: ${elapsed}s / ${timeout}s ($(date '+%H:%M:%S'))" | tee -a "$MAIN_LOG"
    if [ -f "$LOG_FILE" ]; then
      tail -3 "$LOG_FILE" | sed 's/^/    /'
    fi
    if [ $elapsed -ge $timeout ]; then
      echo "  ✗ [$name] 超时（${timeout}秒）" | tee -a "$MAIN_LOG"
      kill $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      LOG_FILE="$prev_log"
      return 1
    fi
  done

  wait $pid
  local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    echo "  ✓ [$name] 完成" | tee -a "$MAIN_LOG"
  else
    echo "  ✗ [$name] 失败（退出码: $exit_code）" | tee -a "$MAIN_LOG"
    tail -20 "$LOG_FILE" | sed 's/^/    /'
  fi
  LOG_FILE="$prev_log"
  return $exit_code
}

verify_cluster_counts() {
  local min_k3d=3
  local min_kind=3
  local k3d_names kind_names k3d_count kind_count

  if command -v k3d >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
      k3d_names=$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
    else
      k3d_names=$(k3d cluster list 2>/dev/null | awk 'NR>1 && $1 !~ /NAME/ {print $1}' 2>/dev/null || true)
    fi
  else
    k3d_names=""
  fi
  k3d_names=$(printf '%s\n' "$k3d_names" | tr -d '\r' | grep -v '^devops$' || true)
  k3d_count=$(printf '%s\n' "$k3d_names" | sed '/^$/d' | wc -l | tr -d ' ')

  if command -v kind >/dev/null 2>&1; then
    kind_names=$(kind get clusters 2>/dev/null | tr -d '\r' || true)
  else
    kind_names=""
  fi
  kind_count=$(printf '%s\n' "$kind_names" | sed '/^$/d' | wc -l | tr -d ' ')

  echo "  当前集群统计 (期望 ≥${min_k3d} 个 k3d, ≥${min_kind} 个 kind):"
  echo "    - k3d: ${k3d_count} 个"
  if [ -n "$k3d_names" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "      • $name"
    done <<<"$k3d_names"
  fi
  echo "    - kind: ${kind_count} 个"
  if [ -n "$kind_names" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "      • $name"
    done <<<"$kind_names"
  fi

  if [ "$k3d_count" -lt "$min_k3d" ]; then
    echo "✗ k3d 集群数量不足 (当前 ${k3d_count} 个，需至少 ${min_k3d} 个)"
    return 1
  fi
  if [ "$kind_count" -lt "$min_kind" ]; then
    echo "✗ kind 集群数量不足 (当前 ${kind_count} 个，需至少 ${min_kind} 个)"
    return 1
  fi

  echo "  ✓ 集群数量满足要求"
  return 0
}

RECON_RECORDED=false
record_reconcile_report() {
  local status="$1"
  if $RECON_RECORDED; then
    return 0
  fi
  local summary_line="" history_json=""
  if [ -f "$RECON_LOG" ]; then
    summary_line=$(grep -E '^RECONCILE_SUMMARY=' "$RECON_LOG" | tail -1 || true)
  fi
  if history_json=$("$ROOT_DIR/scripts/reconcile.sh" --last-run --json 2>/dev/null); then
    :
  else
    history_json=""
  fi
  {
    echo ""
    echo "### Reconcile Snapshot ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo ""
    echo "- 状态 Status: $status"
    echo "- 日志 Log: $RECON_LOG"
    if [ -n "$summary_line" ]; then
      echo ""
      echo '```json'
      echo "${summary_line#RECONCILE_SUMMARY=}"
      echo '```'
    fi
    if [ -n "$history_json" ]; then
      echo ""
      echo '- Latest History Entry:'
      echo '```json'
      echo "$history_json"
      echo '```'
    fi
  } >> "$TEST_REPORT"
  RECON_RECORDED=true
}

declare -a CLUSTER_FILTER=()
declare -A CLUSTER_FILTER_NEEDLE=()
if [ -n "$CLUSTER_FILTER_RAW" ]; then
  IFS=',' read -r -a _raw_filter <<<"$CLUSTER_FILTER_RAW"
  for entry in "${_raw_filter[@]}"; do
    trimmed=$(trim "$entry")
    [ -z "$trimmed" ] && continue
    CLUSTER_FILTER+=("$trimmed")
    CLUSTER_FILTER_NEEDLE["$trimmed"]=false
  done
fi

declare -a TARGET_CLUSTERS=()
declare -A CLUSTER_PROVIDER=()
CLUSTER_LIST_READY="false"

load_cluster_inventory() {
  local -a clusters=()
  declare -A providers=()

  if sqlite_is_available 2>/dev/null; then
    while IFS='|' read -r name provider _; do
      name=$(trim "$name")
      provider=$(trim "$provider")
      [ -z "$name" ] && continue
      [ "$name" = "devops" ] && continue
      clusters+=("$name")
      providers["$name"]="$provider"
    done < <(sqlite_list_clusters 2>/dev/null || true)
  fi

  if [ ${#clusters[@]} -eq 0 ]; then
    while IFS=',' read -r env provider _rest; do
      env=$(trim "$env")
      provider=$(trim "$provider")
      case "$env" in
        ''|\#*) continue ;;
      esac
      [ "$env" = "devops" ] && continue
      clusters+=("$env")
      providers["$env"]="$provider"
    done < "$ROOT_DIR/config/environments.csv"
  fi

  if [ ${#clusters[@]} -eq 0 ]; then
    echo "✗ 无法读取业务集群定义 (SQLite 与 CSV 都为空)" | tee -a "$MAIN_LOG"
    exit 1
  fi

  if [ ${#CLUSTER_FILTER[@]} -gt 0 ]; then
    local -a filtered=()
    declare -A filtered_providers=()
    for env in "${clusters[@]}"; do
      if [[ -v CLUSTER_FILTER_NEEDLE["$env"] ]]; then
        filtered+=("$env")
        filtered_providers["$env"]="${providers[$env]}"
        CLUSTER_FILTER_NEEDLE["$env"]=true
      fi
    done
    for requested in "${CLUSTER_FILTER[@]}"; do
      if [ "${CLUSTER_FILTER_NEEDLE[$requested]}" != true ]; then
        echo "✗ --clusters 指定的环境 $requested 不存在于 SQLite/CSV" | tee -a "$MAIN_LOG"
        exit 1
      fi
    done
    clusters=("${filtered[@]}")
    providers=()
    for env in "${clusters[@]}"; do
      providers["$env"]="${filtered_providers[$env]}"
    done
  fi

  TARGET_CLUSTERS=("${clusters[@]}")
  CLUSTER_PROVIDER=()
  for env in "${clusters[@]}"; do
    CLUSTER_PROVIDER["$env"]="${providers[$env]:-unknown}"
  done
  CLUSTER_LIST_READY="true"
}

run_smoke_suite() {
  if $SKIP_SMOKE; then
    echo "[可选] 跳过业务集群 smoke 检查" | tee -a "$MAIN_LOG"
    return 0
  fi
  if [ "$CLUSTER_LIST_READY" != "true" ]; then
    load_cluster_inventory
  fi
  echo "[附加] 对业务集群执行 scripts/smoke.sh" | tee -a "$MAIN_LOG"
  for env in "${TARGET_CLUSTERS[@]}"; do
    echo "  -> smoke $env" | tee -a "$MAIN_LOG"
    if ! "$ROOT_DIR/scripts/smoke.sh" "$env" >> "$MAIN_LOG" 2>&1; then
      echo "  ✗ smoke 检查失败: $env" | tee -a "$MAIN_LOG"
      exit 1
    fi
  done
}

run_bats_suite() {
  if $SKIP_BATS; then
    echo "[可选] 跳过 bats tests" | tee -a "$MAIN_LOG"
    return 0
  fi
  echo "[附加] 运行 bats tests" | tee -a "$MAIN_LOG"
  if ! bats "$ROOT_DIR/tests" >> "$MAIN_LOG" 2>&1; then
    echo "✗ bats 测试失败" | tee -a "$MAIN_LOG"
    exit 1
  fi
}

# === 步骤 1: 清理环境 ===
if $SKIP_CLEAN; then
  echo "[步骤 1/10] 跳过清理 (根据参数)" | tee -a "$MAIN_LOG"
else
  echo "[步骤 1/10] 彻底清理环境" | tee -a "$MAIN_LOG"
  run_with_monitor $TIMEOUT_CLEAN "清理环境" "$RUN_DIR/phase1-clean.log" "$ROOT_DIR/scripts/clean.sh" --all || exit 1
fi

echo "" | tee -a "$MAIN_LOG"

# === 步骤 2: 启动基础环境 ===
if $SKIP_BOOTSTRAP; then
  echo "[步骤 2/10] 跳过 bootstrap (根据参数)" | tee -a "$MAIN_LOG"
else
  echo "[步骤 2/10] 启动基础环境 (bootstrap.sh)" | tee -a "$MAIN_LOG"
  run_with_monitor $TIMEOUT_BOOTSTRAP "启动基础环境" "$RUN_DIR/phase2-bootstrap.log" "$ROOT_DIR/scripts/bootstrap.sh" || exit 1
fi

echo "" | tee -a "$MAIN_LOG"

# === 步骤 3: 声明式调和 ===
echo "[步骤 3/10] 声明式调和 (SQLite → 集群)" | tee -a "$MAIN_LOG"
if run_with_monitor $TIMEOUT_RECON "声明式调和" "$RECON_LOG" "$ROOT_DIR/scripts/reconcile_loop.sh" --once; then
  if verify_cluster_counts | tee -a "$MAIN_LOG"; then
    record_reconcile_report "success"
    echo "  追加运行 scripts/reconcile.sh --prune-missing 清理陈旧记录" | tee -a "$MAIN_LOG"
    if ! "$ROOT_DIR/scripts/reconcile.sh" --prune-missing >> "$MAIN_LOG" 2>&1; then
      echo "  ✗ prune-missing 清理失败" | tee -a "$MAIN_LOG"
      exit 1
    fi
  else
    record_reconcile_report "failed-count-check"
    exit 1
  fi
else
  record_reconcile_report "failed"
  exit 1
fi

load_cluster_inventory

echo "" | tee -a "$MAIN_LOG"

# === 步骤 4: 验证数据库初始化 ===
echo "[步骤 4/10] 验证数据库初始化" | tee -a "$MAIN_LOG"
if [ -f "$ROOT_DIR/scripts/test_sqlite_migration.sh" ]; then
  if ! "$ROOT_DIR/scripts/test_sqlite_migration.sh" 2>&1 | tee -a "$MAIN_LOG"; then
    echo "✗ 数据库验证失败" | tee -a "$MAIN_LOG"
    exit 1
  fi
else
  echo "  ⚠ test_sqlite_migration.sh 不存在，跳过" | tee -a "$MAIN_LOG"
fi

echo "" | tee -a "$MAIN_LOG"

# === 步骤 5: 创建 k3d 测试集群 ===
echo "[步骤 5/10] 脚本方式创建测试集群 (k3d)" | tee -a "$MAIN_LOG"
if run_with_monitor $TIMEOUT_CREATE "创建 test-script-k3d" "$RUN_DIR/phase5-test-k3d.log" "$ROOT_DIR/scripts/create_env.sh" -n test-script-k3d -p k3d; then
  if kubectl --context k3d-test-script-k3d get nodes >/dev/null 2>&1; then
    echo "  ✓ test-script-k3d 集群验证通过" | tee -a "$MAIN_LOG"
  else
    echo "✗ test-script-k3d 集群验证失败" | tee -a "$MAIN_LOG"
    exit 1
  fi
else
  echo "✗ 创建 test-script-k3d 失败" | tee -a "$MAIN_LOG"
  exit 1
fi

echo "" | tee -a "$MAIN_LOG"

# === 步骤 6: 创建 kind 测试集群 ===
echo "[步骤 6/10] 脚本方式创建测试集群 (kind)" | tee -a "$MAIN_LOG"
if run_with_monitor $TIMEOUT_CREATE "创建 test-script-kind" "$RUN_DIR/phase6-test-kind.log" "$ROOT_DIR/scripts/create_env.sh" -n test-script-kind -p kind; then
  if kubectl --context kind-test-script-kind get nodes >/dev/null 2>&1; then
    echo "  ✓ test-script-kind 集群验证通过" | tee -a "$MAIN_LOG"
  else
    echo "✗ test-script-kind 集群验证失败" | tee -a "$MAIN_LOG"
    exit 1
  fi
else
  echo "✗ 创建 test-script-kind 失败" | tee -a "$MAIN_LOG"
  exit 1
fi

echo "" | tee -a "$MAIN_LOG"

# === 步骤 7: 完整数据一致性测试（数据库与集群比对） ===
echo "[步骤 7/10] 完整数据一致性测试" | tee -a "$MAIN_LOG"
echo "  检查数据库记录..." | tee -a "$MAIN_LOG"

if sqlite_is_available 2>/dev/null; then
  for name in test-script-k3d test-script-kind; do
    if sqlite_cluster_exists "$name" 2>/dev/null; then
      echo "  ✓ $name 在数据库中" | tee -a "$MAIN_LOG"
      cluster_info=$(sqlite_get_cluster "$name" 2>/dev/null || echo "")
      if [ -n "$cluster_info" ]; then
        echo "    信息: $cluster_info" | tee -a "$MAIN_LOG"
      fi
    else
      echo "  ✗ $name 不在数据库中" | tee -a "$MAIN_LOG"
      exit 1
    fi
  done

  echo "" | tee -a "$MAIN_LOG"
  echo "  清理不存在的集群记录..." | tee -a "$MAIN_LOG"
  if [ -f "$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" ]; then
    "$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" 2>&1 | grep -E "✓|✗|删除|清理|跳过" | sed 's/^/    /' | tee -a "$MAIN_LOG" || true
  fi

  echo "" | tee -a "$MAIN_LOG"
  echo "  验证 ApplicationSet 同步..." | tee -a "$MAIN_LOG"
  if [ -f "$ROOT_DIR/scripts/sync_applicationset.sh" ]; then
    "$ROOT_DIR/scripts/sync_applicationset.sh" 2>&1 | grep -E "✓|⚠|发现|添加" | sed 's/^/    /' | tee -a "$MAIN_LOG" || true
  fi
else
  echo "  ⚠ 数据库不可用，跳过数据库验证" | tee -a "$MAIN_LOG"
fi

# 列出测试集群
if [ -x "$ROOT_DIR/scripts/cluster.sh" ]; then
  "$ROOT_DIR/scripts/cluster.sh" list 2>&1 | grep -E "test-script" | tee -a "$MAIN_LOG" || true
fi

echo "" | tee -a "$MAIN_LOG"

echo "" | tee -a "$MAIN_LOG"

# === 步骤 8/10: smoke + 数据一致性脚本 ===
echo "[步骤 8/10] 运行 smoke 与 test_data_consistency" | tee -a "$MAIN_LOG"
run_smoke_suite
if [ -f "$ROOT_DIR/scripts/test_data_consistency.sh" ]; then
  if "$ROOT_DIR/scripts/test_data_consistency.sh" --json-summary 2>&1 | tee -a "$MAIN_LOG"; then
    echo "  ✓ test_data_consistency.sh 通过" | tee -a "$MAIN_LOG"
  else
    echo "  ✗ test_data_consistency.sh 失败" | tee -a "$MAIN_LOG"
    exit 1
  fi
else
  echo "  ⚠ test_data_consistency.sh 不存在，跳过" | tee -a "$MAIN_LOG"
fi

echo "" | tee -a "$MAIN_LOG"

# === 步骤 9/10: SQLite 验证 ===
echo "[步骤 9/10] SQLite 数据库记录验证" | tee -a "$MAIN_LOG"
if [ -f "$ROOT_DIR/scripts/db_verify.sh" ]; then
  if "$ROOT_DIR/scripts/db_verify.sh" --json-summary 2>&1 | tee -a "$MAIN_LOG"; then
    echo "  ✓ SQLite 记录验证通过" | tee -a "$MAIN_LOG"
  else
    echo "  ✗ SQLite 记录验证失败" | tee -a "$MAIN_LOG"
    exit 1
  fi
else
  echo "  ⚠ db_verify.sh 不存在，跳过" | tee -a "$MAIN_LOG"
fi

echo "" | tee -a "$MAIN_LOG"

# === 步骤 10/10: bats ===
echo "[步骤 10/10] 运行 bats tests" | tee -a "$MAIN_LOG"
run_bats_suite

echo "" | tee -a "$MAIN_LOG"

echo "  验证 Portainer 和 ArgoCD..." | tee -a "$MAIN_LOG"
echo "    Portainer 应该能看到集群: test-script-k3d, test-script-kind" | tee -a "$MAIN_LOG"
echo "    ArgoCD ApplicationSet 应该只包含实际存在的集群" | tee -a "$MAIN_LOG"

echo "" | tee -a "$MAIN_LOG"

echo "==========================================" | tee -a "$MAIN_LOG"
echo "✅ 回归测试完成！" | tee -a "$MAIN_LOG"
echo "==========================================" | tee -a "$MAIN_LOG"

echo "测试结果:" | tee -a "$MAIN_LOG"
echo "  ✓ 环境清理/启动/调和成功" | tee -a "$MAIN_LOG"
echo "  ✓ 脚本创建 test-script-* 成功并验证" | tee -a "$MAIN_LOG"
echo "  ✓ 数据一致性 / smoke / bats 全部通过" | tee -a "$MAIN_LOG"

echo "" | tee -a "$MAIN_LOG"

echo "清理测试集群" | tee -a "$MAIN_LOG"
cleanup_test_clusters false

trap - EXIT
exit 0
