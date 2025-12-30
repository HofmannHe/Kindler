#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 测试覆盖率评估工具
# 分析项目的测试覆盖情况，识别测试盲区和无效测试

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/docs/evaluation"
OUTPUT_FILE="${OUTPUT_DIR}/test_coverage_report.md"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# 显示帮助信息
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

测试覆盖率评估工具 - 分析项目的测试覆盖情况

OPTIONS:
    -h, --help              显示此帮助信息
    -o, --output FILE       指定输出文件路径 (默认: ${OUTPUT_FILE})
    -v, --verbose           详细输出模式

EXAMPLES:
    $(basename "$0")                    # 生成测试覆盖率报告
    $(basename "$0") -v                 # 详细输出模式

EOF
}

# 解析命令行参数
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 确保输出目录存在
mkdir -p "$(dirname "$OUTPUT_FILE")"

# 收集所有测试文件
collect_test_files() {
    local test_files=()

    # 查找tests/目录下的测试脚本
    while IFS= read -r -d '' file; do
        test_files+=("$file")
    done < <(find "${ROOT_DIR}/tests" -type f \( -name "*.sh" -o -name "*.bats" \) -print0 2>/dev/null || true)

    echo "${test_files[@]}"
}

# 收集所有源代码文件
collect_source_files() {
    local source_files=()

    # 查找scripts/和tools/目录下的脚本
    while IFS= read -r -d '' file; do
        source_files+=("$file")
    done < <(find "${ROOT_DIR}/scripts" "${ROOT_DIR}/tools" -type f -name "*.sh" \
        ! -path "*/archive/*" \
        ! -path "*/worktrees/*" \
        -print0 2>/dev/null || true)

    echo "${source_files[@]}"
}

# 分析测试文件覆盖的源文件
analyze_test_coverage() {
    local test_file="$1"
    local covered_files=()

    # 读取测试文件内容
    while IFS= read -r line; do
        # 查找source语句
        if [[ "$line" =~ source[[:space:]]+([^[:space:]]+) ]] || [[ "$line" =~ \.[[:space:]]+([^[:space:]]+) ]]; then
            local sourced="${BASH_REMATCH[1]}"
            sourced="${sourced//\"/}"
            sourced="${sourced//\'/}"

            # 转换为绝对路径
            if [[ "$sourced" == \$* ]]; then
                continue
            elif [[ -f "${ROOT_DIR}/${sourced}" ]]; then
                covered_files+=("${sourced}")
            fi
        fi

        # 查找被测试的脚本调用
        if [[ "$line" =~ (scripts|tools)/[^[:space:]]+ ]]; then
            local script="${BASH_REMATCH[0]}"
            if [[ -f "${ROOT_DIR}/${script}" ]]; then
                covered_files+=("${script}")
            fi
        fi
    done < "$test_file"

    # 去重
    printf '%s\n' "${covered_files[@]}" | sort -u
}

# 检查测试文件状态
check_test_status() {
    local test_file="$1"
    local status="active"
    local reason=""

    # 检查是否被跳过
    if grep -q "skip\|SKIP\|@test.*#" "$test_file" 2>/dev/null; then
        status="skipped"
        reason="包含跳过的测试"
    fi

    # 检查最后修改时间
    local last_modified
    last_modified=$(git log -1 --format="%ai" -- "$test_file" 2>/dev/null || echo "unknown")
    if [[ "$last_modified" != "unknown" ]]; then
        local last_modified_epoch
        last_modified_epoch=$(date -d "$last_modified" +%s 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local days_ago=$(( (now_epoch - last_modified_epoch) / 86400 ))

        if [[ $days_ago -gt 180 ]]; then
            status="stale"
            reason="超过6个月未修改"
        fi
    fi

    echo "${status}|${reason}"
}

# 主函数
main() {
    log_info "开始分析测试覆盖率..."
    log_info "项目根目录: ${ROOT_DIR}"
    log_info "输出文件: ${OUTPUT_FILE}"

    # 收集测试文件和源文件
    local test_files
    test_files=($(collect_test_files))
    local source_files
    source_files=($(collect_source_files))

    log_info "找到 ${#test_files[@]} 个测试文件"
    log_info "找到 ${#source_files[@]} 个源文件"

    # 分析每个测试文件
    declare -A test_coverage
    declare -A test_status
    declare -A source_covered

    for test_file in "${test_files[@]}"; do
        local relative_path="${test_file#${ROOT_DIR}/}"
        if [[ $VERBOSE -eq 1 ]]; then
            log_info "分析测试文件: ${relative_path}"
        fi

        # 分析覆盖的源文件
        local covered
        covered=$(analyze_test_coverage "$test_file")
        test_coverage["$relative_path"]="$covered"

        # 标记被覆盖的源文件
        for src in $covered; do
            source_covered["$src"]=1
        done

        # 检查测试状态
        local status_info
        status_info=$(check_test_status "$test_file")
        test_status["$relative_path"]="$status_info"
    done

    # 识别未被覆盖的源文件
    local uncovered_sources=()
    for source_file in "${source_files[@]}"; do
        local relative_path="${source_file#${ROOT_DIR}/}"
        if [[ -z "${source_covered[$relative_path]:-}" ]]; then
            uncovered_sources+=("$relative_path")
        fi
    done

    # 生成报告
    generate_report

    log_info "分析完成！报告已保存到: ${OUTPUT_FILE}"
}

# 生成报告
generate_report() {
    cat > "$OUTPUT_FILE" <<EOF
# 测试覆盖率分析报告

**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
**分析范围**: 项目测试目录

## 执行摘要

- **测试文件总数**: ${#test_files[@]}
- **源文件总数**: ${#source_files[@]}
- **已覆盖源文件**: $((${#source_files[@]} - ${#uncovered_sources[@]}))
- **未覆盖源文件**: ${#uncovered_sources[@]}
- **覆盖率**: $(( (${#source_files[@]} - ${#uncovered_sources[@]}) * 100 / ${#source_files[@]} ))%

### 测试状态统计

EOF

    # 统计测试状态
    local active=0
    local skipped=0
    local stale=0

    for test_file in "${!test_status[@]}"; do
        local status
        status=$(echo "${test_status[$test_file]}" | cut -d'|' -f1)
        case "$status" in
            active) active=$((active + 1)) ;;
            skipped) skipped=$((skipped + 1)) ;;
            stale) stale=$((stale + 1)) ;;
        esac
    done

    cat >> "$OUTPUT_FILE" <<EOF
- **活跃测试**: ${active} ($(( active * 100 / ${#test_files[@]} ))%)
- **跳过的测试**: ${skipped} ($(( skipped * 100 / ${#test_files[@]} ))%)
- **过时测试**: ${stale} ($(( stale * 100 / ${#test_files[@]} ))%)

## 未覆盖的源文件

以下源文件没有对应的测试用例：

| 文件路径 | 文件类型 |
|---------|---------|
EOF

    for source in "${uncovered_sources[@]}"; do
        local file_type="script"
        if [[ "$source" == scripts/lib/* ]]; then
            file_type="library"
        elif [[ "$source" == tools/* ]]; then
            file_type="tool"
        fi
        echo "| ${source} | ${file_type} |" >> "$OUTPUT_FILE"
    done

    cat >> "$OUTPUT_FILE" <<EOF

## 测试文件详情

### 活跃测试

| 测试文件 | 覆盖的源文件数 | 覆盖的源文件 |
|---------|--------------|------------|
EOF

    for test_file in "${!test_status[@]}"; do
        local status
        status=$(echo "${test_status[$test_file]}" | cut -d'|' -f1)
        if [[ "$status" == "active" ]]; then
            local covered="${test_coverage[$test_file]}"
            local count
            count=$(echo "$covered" | wc -w)
            local covered_list
            covered_list=$(echo "$covered" | tr '\n' ', ' | sed 's/, $//')
            echo "| ${test_file} | ${count} | ${covered_list} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

### 跳过的测试

| 测试文件 | 原因 |
|---------|------|
EOF

    for test_file in "${!test_status[@]}"; do
        local status reason
        status=$(echo "${test_status[$test_file]}" | cut -d'|' -f1)
        reason=$(echo "${test_status[$test_file]}" | cut -d'|' -f2)
        if [[ "$status" == "skipped" ]]; then
            echo "| ${test_file} | ${reason} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

### 过时的测试

| 测试文件 | 原因 |
|---------|------|
EOF

    for test_file in "${!test_status[@]}"; do
        local status reason
        status=$(echo "${test_status[$test_file]}" | cut -d'|' -f1)
        reason=$(echo "${test_status[$test_file]}" | cut -d'|' -f2)
        if [[ "$status" == "stale" ]]; then
            echo "| ${test_file} | ${reason} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

## 测试覆盖率分析

### 按模块统计

#### scripts/ 目录

EOF

    local scripts_total=0
    local scripts_covered=0
    for source in "${source_files[@]}"; do
        local relative_path="${source#${ROOT_DIR}/}"
        if [[ "$relative_path" == scripts/* ]]; then
            scripts_total=$((scripts_total + 1))
            if [[ -n "${source_covered[$relative_path]:-}" ]]; then
                scripts_covered=$((scripts_covered + 1))
            fi
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF
- **总文件数**: ${scripts_total}
- **已覆盖**: ${scripts_covered}
- **覆盖率**: $(( scripts_covered * 100 / scripts_total ))%

#### tools/ 目录

EOF

    local tools_total=0
    local tools_covered=0
    for source in "${source_files[@]}"; do
        local relative_path="${source#${ROOT_DIR}/}"
        if [[ "$relative_path" == tools/* ]]; then
            tools_total=$((tools_total + 1))
            if [[ -n "${source_covered[$relative_path]:-}" ]]; then
                tools_covered=$((tools_covered + 1))
            fi
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF
- **总文件数**: ${tools_total}
- **已覆盖**: ${tools_covered}
- **覆盖率**: $(( tools_covered * 100 / tools_total ))%

## 改进建议

### 高优先级
1. 为未覆盖的核心脚本添加测试用例（scripts/目录）
2. 修复或删除跳过的测试（${skipped}个）
3. 更新过时的测试（${stale}个）

### 中优先级
1. 提高整体覆盖率到85%以上
2. 为工具脚本添加单元测试（tools/目录）
3. 增加边界条件和异常处理的测试

### 低优先级
1. 添加性能测试
2. 添加并发测试
3. 完善集成测试

## 测试质量建议

1. **测试命名规范**: 使用描述性的测试名称
2. **测试独立性**: 每个测试应该独立运行
3. **测试覆盖**: 覆盖正常流程、边界条件和异常情况
4. **测试维护**: 定期更新测试，保持与代码同步

---
**报告生成工具**: tools/evaluation/analyze_coverage.sh
**版本**: 1.0
EOF
}

# 执行主函数
main "$@"
