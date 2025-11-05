#!/usr/bin/env bash
# 完整回归测试脚本
# 用途：自动化执行从清理到验证的完整测试流程

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs/regression"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ROUND=${1:-1}

# 创建日志目录
mkdir -p "$LOG_DIR"

# 日志文件
SUMMARY_LOG="${LOG_DIR}/regression_round${ROUND}_${TIMESTAMP}.log"
STEP_LOG="${LOG_DIR}/step_${TIMESTAMP}.log"

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 记录容器重启计数
log_restart_counts() {
    local containers=("haproxy-gw" "portainer-ce" "kindler-webui-backend" "kindler-webui-frontend")
    echo "Restart counters:" | tee -a "$SUMMARY_LOG"
    for c in "${containers[@]}"; do
        if docker inspect "$c" >/dev/null 2>&1; then
            local rc status
            rc=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo "n/a")
            status=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "n/a")
            echo "  - $c: restart=$rc status=$status" | tee -a "$SUMMARY_LOG"
        else
            echo "  - $c: not running" | tee -a "$SUMMARY_LOG"
        fi
    done
}

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$SUMMARY_LOG"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*" | tee -a "$SUMMARY_LOG"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*" | tee -a "$SUMMARY_LOG"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$SUMMARY_LOG"
}

# 执行带超时的命令（带实时输出）
# 参数: 超时时间(秒) 描述 命令...
run_with_timeout() {
    local timeout_sec=$1
    local description=$2
    shift 2
    local cmd="$*"
    
    log_info "=========================================="
    log_info "开始: $description"
    log_info "超时: ${timeout_sec}s"
    log_info "命令: $cmd"
    log_info "=========================================="
    
    # 使用临时文件记录输出和退出码
    local output_file="${STEP_LOG}.$$"
    local exit_code_file="${STEP_LOG}.$$.exit"
    
    # 在后台运行命令，记录输出和退出码
    (
        set +e
        eval "$cmd" > "$output_file" 2>&1
        echo $? > "$exit_code_file"
    ) &
    local cmd_pid=$!
    
    # 等待命令完成或超时，实时输出进度
    local elapsed=0
    local last_size=0
    local last_tail_line=0
    
    while [ $elapsed -lt $timeout_sec ]; do
        if ! kill -0 $cmd_pid 2>/dev/null; then
            # 命令已完成
            wait $cmd_pid 2>/dev/null || true
            local exit_code=$(cat "$exit_code_file" 2>/dev/null || echo "1")
            
            # 输出最后的新内容
            local current_size=$(wc -l < "$output_file" 2>/dev/null || echo "0")
            echo ""
            echo "========== 任务执行完成 =========="
            if [ "$current_size" -gt "$last_tail_line" ]; then
                echo "📋 最终输出 (最后10行):"
                tail -10 "$output_file" | sed 's/^/  │ /'
            fi
            echo "=================================="
            echo ""
            
            # 完整日志到文件
            cat "$output_file" >> "$SUMMARY_LOG"
            rm -f "$output_file" "$exit_code_file"
            
            if [ "$exit_code" -eq 0 ]; then
                log_success "✅ $description 完成 (耗时: ${elapsed}s)"
                return 0
            else
                log_error "❌ $description 失败 (退出码: $exit_code, 耗时: ${elapsed}s)"
                return 1
            fi
        fi
        
        # 每2秒输出一次进度和最新内容（更频繁，防止网络超时）
        if [ $((elapsed % 2)) -eq 0 ]; then
            local current_size=$(wc -l < "$output_file" 2>/dev/null || echo "0")
            
            # 输出进度条（带强制刷新）
            local progress=$((elapsed * 100 / timeout_sec))
            echo -e "${BLUE}⏱  ${elapsed}s/${timeout_sec}s (${progress}%) | 输出: ${current_size}行${NC}" | tee -a "$SUMMARY_LOG"
            
            # 如果有新内容，输出最新的2行
            if [ "$current_size" -gt "$last_tail_line" ]; then
                echo "📝 最新进展:" | tee -a "$SUMMARY_LOG"
                tail -n 2 "$output_file" 2>/dev/null | sed 's/^/  📄 /' | tee -a "$SUMMARY_LOG"
                last_tail_line=$current_size
            else
                # 即使没有新内容，也输出心跳信息
                echo "  💓 运行中..." | tee -a "$SUMMARY_LOG"
            fi
        fi
        
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    # 超时处理
    echo ""
    echo "=========================================="
    log_error "⏰ $description 超时 (${timeout_sec}s)"
    echo "=========================================="
    kill -9 $cmd_pid 2>/dev/null || true
    wait $cmd_pid 2>/dev/null || true
    
    # 输出最后10行
    if [ -f "$output_file" ]; then
        echo ""
        echo "📋 超时时的输出 (最后10行):"
        tail -10 "$output_file" | sed 's/^/  │ /'
        echo ""
        cat "$output_file" >> "$SUMMARY_LOG"
        rm -f "$output_file"
    fi
    rm -f "$exit_code_file"
    
    return 1
}

# 主测试流程
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                                                      ║"
    echo "║      🚀  Kindler 完整回归测试 Round $ROUND  🚀         ║"
    echo "║                                                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    log_info "⏰ 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "📝 日志文件: $SUMMARY_LOG"
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  测试流程:"
    echo "    1️⃣  完全清理环境 (300s)"
    echo "    2️⃣  部署基础环境 (600s)"
    echo "    3️⃣  创建业务集群（并行）"
    echo "    4️⃣  执行测试套件 (1020s = 6个测试)"
    echo "════════════════════════════════════════════════════════"
    echo ""
    sleep 2
    
    # 步骤1: 完全清理
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║  步骤 1/4: 完全清理环境                ║"
    echo "╚════════════════════════════════════════╝"
    if ! run_with_timeout 300 "步骤1: 完全清理环境" \
        "$ROOT_DIR/scripts/clean.sh --all --verify"; then
        log_error "❌ 清理失败，终止测试"
        exit 1
    fi
    
    # 步骤2: 部署基础环境
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║  步骤 2/4: 部署基础环境                ║"
    echo "╚════════════════════════════════════════╝"
    if ! run_with_timeout 600 "步骤2: 部署基础环境" \
        "$ROOT_DIR/scripts/bootstrap.sh"; then
        log_error "❌ 基础环境部署失败，终止测试"
        exit 1
    fi
    # 基础环境部署后打印关键容器重启计数（用于区分主动重载 vs 异常重启）
    log_info "[诊断] 基础容器重启计数"
    log_restart_counts
    
    # 步骤3: 创建业务集群（动态：从 CSV 读取，排除 devops）
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║  步骤 3/4: 创建业务集群（并行创建）     ║"
    echo "╚════════════════════════════════════════╝"
    # 使用并行批量创建脚本，从 CSV 读取业务集群（默认排除 devops）
    # 默认最大并发数 6，可通过环境变量 REGRESSION_MAX_PARALLEL 覆盖
    MAXP="${REGRESSION_MAX_PARALLEL:-6}"
    if ! run_with_timeout 1800 "并行创建业务集群（max-parallel=$MAXP）" \
        "$ROOT_DIR/scripts/batch_create_envs.sh --max-parallel $MAXP"; then
        log_error "❌ 并行创建业务集群失败，终止测试"
        exit 1
    fi
    
    # 等待集群稳定
    log_info "=========================================="
    log_info "等待集群稳定（30秒）..."
    log_info "=========================================="
    for i in {1..30}; do
        printf "${BLUE}⏱  等待中: %2d/30 秒${NC}\r" "$i"
        sleep 1
    done
    echo ""
    log_info "✓ 集群稳定等待完成"
    # 同步 HAProxy 路由（确保动态区块与 DB 一致，且已连接各集群网络）
    log_info "[维护] 同步 HAProxy 路由并修剪缺失环境"
    "$ROOT_DIR/scripts/haproxy_sync.sh" --prune >> "$SUMMARY_LOG" 2>&1 || true
    sleep 2
    # 路由同步后再次打印重启计数（haproxy 预期会有一次重启）
    log_info "[诊断] 路由同步后的重启计数"
    log_restart_counts
    
    # 步骤4: 运行测试套件
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║  步骤 4/4: 执行测试套件 (共6个测试)    ║"
    echo "╚════════════════════════════════════════╝"
    
    local test_modules=(
        "portainer_test.sh:120:Portainer集成测试"
        "portainer_login_test.sh:120:Portainer登录测试"
        "haproxy_test.sh:120:HAProxy路由测试"
        "haproxy_config_unit_test.sh:60:HAProxy配置单元测试"
        "services_test.sh:180:服务访问测试"
        "cluster_lifecycle_test.sh:300:集群生命周期测试"
        "four_source_consistency_test.sh:120:四源一致性测试"
        "webui_visibility_test.sh:60:WebUI集群可见性测试"
        "webui_create_delete_cycles_test.sh:1200:WebUI并发创建删除循环(3轮)"
    )
    
    local failed_tests=()
    local test_count=0
    local total_tests=${#test_modules[@]}
    
    for test_info in "${test_modules[@]}"; do
        test_count=$((test_count + 1))
        IFS=':' read -r test_file timeout_val test_name <<< "$test_info"
        
        echo ""
        echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
        log_info "┃ 🧪 测试 ${test_count}/${total_tests}: $test_name"
        echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
        
        if ! run_with_timeout "$timeout_val" "$test_name" \
            "$ROOT_DIR/tests/$test_file"; then
            log_error "❌ 测试 ${test_count}/${total_tests} 失败: $test_name"
            failed_tests+=("$test_name")
        else
            log_success "✅ 测试 ${test_count}/${total_tests} 通过: $test_name"
        fi
        
        # 在关键生命周期类测试后修剪路由，避免遗留临时 use_backend 影响后续
        if echo "$test_file" | grep -qE "cluster_lifecycle_test\.sh|four_source_consistency_test\.sh"; then
            log_info "[维护] 修剪 HAProxy 动态路由以清理临时环境"
            "$ROOT_DIR/scripts/haproxy_sync.sh" --prune >> "$SUMMARY_LOG" 2>&1 || true
            sleep 1
        fi

        # 短暂停顿，避免测试之间相互影响
        echo "  💤 休息2秒..."
        sleep 2
    done
    
    # 测试结果汇总
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                                                      ║"
    echo "║         📊 回归测试 Round $ROUND 结果汇总              ║"
    echo "║                                                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    log_info "⏰ 开始时间: $(date -r "$SUMMARY_LOG" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
    log_info "⏰ 结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    log_info "📈 总测试数: ${total_tests}"
    log_info "✅ 通过测试: $((total_tests - ${#failed_tests[@]}))"
    log_info "❌ 失败测试: ${#failed_tests[@]}"
    echo ""
    echo "════════════════════════════════════════════════════════"
    
    if [ ${#failed_tests[@]} -eq 0 ]; then
        echo ""
        echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
        echo "┃                                                ┃"
        echo "┃  🎉🎉🎉  所有测试通过！Round $ROUND 成功完成！  🎉🎉🎉  ┃"
        echo "┃                                                ┃"
        echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
        echo ""
        log_info "📝 详细日志: $SUMMARY_LOG"
        echo ""
        log_info "[诊断] 结束时的重启计数"
        log_restart_counts
        return 0
    else
        echo ""
        echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
        echo "┃                                                ┃"
        echo "┃  ⚠️  发现失败的测试 (${#failed_tests[@]}/${total_tests})              ┃"
        echo "┃                                                ┃"
        echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
        echo ""
        log_error "失败的测试列表:"
        for test in "${failed_tests[@]}"; do
            log_error "  ❌ $test"
        done
        echo ""
        log_info "📝 详细日志: $SUMMARY_LOG"
        log_warn "⚠️  请修复上述问题后，从 Round 1 重新开始完整回归测试"
        log_info "[诊断] 结束时的重启计数"
        log_restart_counts
        echo ""
        return 1
    fi
}

# 捕获中断信号
trap 'log_error "测试被中断"; exit 130' INT TERM

# 执行主流程
main
exit $?
