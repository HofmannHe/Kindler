#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 代码使用分析工具
# 分析项目中的代码文件使用情况，识别冗余和未使用的文件

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/docs/evaluation"
OUTPUT_FILE="${OUTPUT_DIR}/code_usage_report.md"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

代码使用分析工具 - 分析项目中的代码文件使用情况

OPTIONS:
    -h, --help              显示此帮助信息
    -o, --output FILE       指定输出文件路径 (默认: ${OUTPUT_FILE})
    -v, --verbose           详细输出模式
    --months N              标记 N 个月未修改的文件 (默认: 6)
    --format FORMAT         输出格式: markdown|json (默认: markdown)

EXAMPLES:
    $(basename "$0")                    # 生成默认报告
    $(basename "$0") --months 12        # 标记12个月未修改的文件
    $(basename "$0") --format json      # 输出JSON格式

EOF
}

# 解析命令行参数
VERBOSE=0
MONTHS_THRESHOLD=6
OUTPUT_FORMAT="markdown"

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
        --months)
            MONTHS_THRESHOLD="$2"
            shift 2
            ;;
        --format)
            OUTPUT_FORMAT="$2"
            shift 2
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

# 分析文件使用情况
analyze_file_usage() {
    local file="$1"
    local relative_path="${file#${ROOT_DIR}/}"

    # 获取最后修改时间
    local last_modified
    last_modified=$(git log -1 --format="%ai" -- "$file" 2>/dev/null || echo "unknown")

    # 计算距今天数
    local days_ago="N/A"
    if [[ "$last_modified" != "unknown" ]]; then
        local last_modified_epoch
        last_modified_epoch=$(date -d "$last_modified" +%s 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        days_ago=$(( (now_epoch - last_modified_epoch) / 86400 ))
    fi

    # 统计引用次数（在其他文件中被source或import）
    local ref_count=0
    case "$file" in
        *.sh)
            # Shell脚本：查找source语句
            ref_count=$(grep -r "source.*${relative_path}" "${ROOT_DIR}" 2>/dev/null | grep -v "^${file}:" | wc -l || echo "0")
            ref_count=$((ref_count + $(grep -r "\. .*${relative_path}" "${ROOT_DIR}" 2>/dev/null | grep -v "^${file}:" | wc -l || echo "0")))
            ;;
        *.py)
            # Python文件：查找import语句
            local module_name
            module_name=$(basename "$file" .py)
            ref_count=$(grep -r "import.*${module_name}" "${ROOT_DIR}" 2>/dev/null | grep -v "^${file}:" | wc -l || echo "0")
            ref_count=$((ref_count + $(grep -r "from.*${module_name}" "${ROOT_DIR}" 2>/dev/null | grep -v "^${file}:" | wc -l || echo "0")))
            ;;
        *.yaml|*.yml)
            # YAML文件：查找引用
            ref_count=$(grep -r "${relative_path}" "${ROOT_DIR}" 2>/dev/null | grep -v "^${file}:" | wc -l || echo "0")
            ;;
    esac

    # 判断是否为冗余文件
    local status="active"
    local reason=""

    if [[ "$days_ago" != "N/A" ]] && [[ $days_ago -gt $((MONTHS_THRESHOLD * 30)) ]]; then
        if [[ $ref_count -eq 0 ]]; then
            status="redundant"
            reason="超过${MONTHS_THRESHOLD}个月未修改且无引用"
        else
            status="stale"
            reason="超过${MONTHS_THRESHOLD}个月未修改但有引用"
        fi
    elif [[ $ref_count -eq 0 ]]; then
        # 检查是否为入口脚本（在scripts/目录下且可执行）
        if [[ "$file" == "${ROOT_DIR}/scripts/"* ]] && [[ -x "$file" ]]; then
            status="entry_point"
            reason="入口脚本（无引用正常）"
        else
            status="unused"
            reason="无引用"
        fi
    fi

    echo "${relative_path}|${last_modified}|${days_ago}|${ref_count}|${status}|${reason}"
}

# 主函数
main() {
    log_info "开始分析代码使用情况..."
    log_info "项目根目录: ${ROOT_DIR}"
    log_info "输出文件: ${OUTPUT_FILE}"
    log_info "时间阈值: ${MONTHS_THRESHOLD} 个月"

    # 收集所有代码文件
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "${ROOT_DIR}" -type f \( -name "*.sh" -o -name "*.py" -o -name "*.yaml" -o -name "*.yml" \) \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        ! -path "*/venv/*" \
        ! -path "*/archive/*" \
        ! -path "*/worktrees/*" \
        -print0)

    log_info "找到 ${#files[@]} 个代码文件"

    # 分析每个文件
    local results=()
    local count=0
    for file in "${files[@]}"; do
        count=$((count + 1))
        if [[ $VERBOSE -eq 1 ]]; then
            log_info "分析 [${count}/${#files[@]}]: ${file#${ROOT_DIR}/}"
        fi
        results+=("$(analyze_file_usage "$file")")
    done

    # 生成报告
    if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
        generate_markdown_report "${results[@]}"
    else
        generate_json_report "${results[@]}"
    fi

    log_info "分析完成！报告已保存到: ${OUTPUT_FILE}"
}

# 生成Markdown报告
generate_markdown_report() {
    local results=("$@")

    cat > "$OUTPUT_FILE" <<EOF
# 代码使用情况分析报告

**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
**分析范围**: 项目根目录
**时间阈值**: ${MONTHS_THRESHOLD} 个月

## 执行摘要

EOF

    # 统计数据
    local total=${#results[@]}
    local redundant=0
    local unused=0
    local stale=0
    local active=0
    local entry_point=0

    for result in "${results[@]}"; do
        local status
        status=$(echo "$result" | cut -d'|' -f5)
        case "$status" in
            redundant) redundant=$((redundant + 1)) ;;
            unused) unused=$((unused + 1)) ;;
            stale) stale=$((stale + 1)) ;;
            active) active=$((active + 1)) ;;
            entry_point) entry_point=$((entry_point + 1)) ;;
        esac
    done

    cat >> "$OUTPUT_FILE" <<EOF
- **总文件数**: ${total}
- **活跃文件**: ${active} ($(( active * 100 / total ))%)
- **入口脚本**: ${entry_point} ($(( entry_point * 100 / total ))%)
- **过时文件**: ${stale} ($(( stale * 100 / total ))%)
- **未使用文件**: ${unused} ($(( unused * 100 / total ))%)
- **冗余文件**: ${redundant} ($(( redundant * 100 / total ))%)

**清理建议**: 可安全删除 ${redundant} 个冗余文件，审查 ${unused} 个未使用文件

## 冗余文件列表（建议删除）

| 文件路径 | 最后修改时间 | 距今天数 | 引用次数 | 原因 |
|---------|------------|---------|---------|------|
EOF

    for result in "${results[@]}"; do
        local status
        status=$(echo "$result" | cut -d'|' -f5)
        if [[ "$status" == "redundant" ]]; then
            local path last_modified days_ago ref_count reason
            IFS='|' read -r path last_modified days_ago ref_count status reason <<< "$result"
            echo "| ${path} | ${last_modified} | ${days_ago} | ${ref_count} | ${reason} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

## 未使用文件列表（需审查）

| 文件路径 | 最后修改时间 | 距今天数 | 引用次数 | 原因 |
|---------|------------|---------|---------|------|
EOF

    for result in "${results[@]}"; do
        local status
        status=$(echo "$result" | cut -d'|' -f5)
        if [[ "$status" == "unused" ]]; then
            local path last_modified days_ago ref_count reason
            IFS='|' read -r path last_modified days_ago ref_count status reason <<< "$result"
            echo "| ${path} | ${last_modified} | ${days_ago} | ${ref_count} | ${reason} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

## 过时文件列表（需更新）

| 文件路径 | 最后修改时间 | 距今天数 | 引用次数 | 原因 |
|---------|------------|---------|---------|------|
EOF

    for result in "${results[@]}"; do
        local status
        status=$(echo "$result" | cut -d'|' -f5)
        if [[ "$status" == "stale" ]]; then
            local path last_modified days_ago ref_count reason
            IFS='|' read -r path last_modified days_ago ref_count status reason <<< "$result"
            echo "| ${path} | ${last_modified} | ${days_ago} | ${ref_count} | ${reason} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

## 完整文件列表

| 文件路径 | 最后修改时间 | 距今天数 | 引用次数 | 状态 | 备注 |
|---------|------------|---------|---------|------|------|
EOF

    for result in "${results[@]}"; do
        local path last_modified days_ago ref_count status reason
        IFS='|' read -r path last_modified days_ago ref_count status reason <<< "$result"
        echo "| ${path} | ${last_modified} | ${days_ago} | ${ref_count} | ${status} | ${reason} |" >> "$OUTPUT_FILE"
    done

    cat >> "$OUTPUT_FILE" <<EOF

## 清理建议

### 高优先级（可立即删除）
- 冗余文件（${redundant}个）：超过${MONTHS_THRESHOLD}个月未修改且无引用

### 中优先级（需审查后删除）
- 未使用文件（${unused}个）：无引用但可能是新增或独立工具

### 低优先级（需更新）
- 过时文件（${stale}个）：超过${MONTHS_THRESHOLD}个月未修改但仍有引用，建议审查是否需要更新

## 注意事项

1. 删除前请确认文件确实不再需要
2. 建议先归档到 \`archive/\` 目录而非直接删除
3. 删除后运行完整回归测试验证功能
4. 入口脚本无引用是正常现象，不应删除

---
**报告生成工具**: tools/evaluation/analyze_code.sh
**版本**: 1.0
EOF
}

# 生成JSON报告
generate_json_report() {
    local results=("$@")

    echo "{" > "$OUTPUT_FILE"
    echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$OUTPUT_FILE"
    echo "  \"months_threshold\": ${MONTHS_THRESHOLD}," >> "$OUTPUT_FILE"
    echo "  \"files\": [" >> "$OUTPUT_FILE"

    local first=1
    for result in "${results[@]}"; do
        local path last_modified days_ago ref_count status reason
        IFS='|' read -r path last_modified days_ago ref_count status reason <<< "$result"

        if [[ $first -eq 0 ]]; then
            echo "," >> "$OUTPUT_FILE"
        fi
        first=0

        cat >> "$OUTPUT_FILE" <<EOF
    {
      "path": "${path}",
      "last_modified": "${last_modified}",
      "days_ago": ${days_ago},
      "ref_count": ${ref_count},
      "status": "${status}",
      "reason": "${reason}"
    }
EOF
    done

    echo "" >> "$OUTPUT_FILE"
    echo "  ]" >> "$OUTPUT_FILE"
    echo "}" >> "$OUTPUT_FILE"
}

# 执行主函数
main "$@"
