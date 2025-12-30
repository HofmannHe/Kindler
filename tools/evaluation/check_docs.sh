#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 文档一致性检查工具
# 检查文档与代码的一致性，识别过时和错误的文档

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/docs/evaluation"
OUTPUT_FILE="${OUTPUT_DIR}/doc_consistency_report.md"

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

文档一致性检查工具 - 检查文档与代码的一致性

OPTIONS:
    -h, --help              显示此帮助信息
    -o, --output FILE       指定输出文件路径 (默认: ${OUTPUT_FILE})
    -v, --verbose           详细输出模式

EXAMPLES:
    $(basename "$0")                    # 检查文档一致性
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

# 收集所有文档文件
collect_doc_files() {
    local doc_files=()

    # 查找Markdown文档
    while IFS= read -r -d '' file; do
        doc_files+=("$file")
    done < <(find "${ROOT_DIR}" -type f -name "*.md" \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        ! -path "*/archive/*" \
        ! -path "*/worktrees/*" \
        -print0)

    echo "${doc_files[@]}"
}

# 检查文档中引用的文件是否存在
check_file_references() {
    local doc_file="$1"
    local issues=()

    while IFS= read -r line; do
        # 匹配文件路径引用（多种格式）
        # 1. Markdown链接: [text](path)
        # 2. 代码块中的路径: `path`
        # 3. 直接路径: scripts/xxx.sh, tools/xxx.sh

        # 提取所有可能的文件路径
        local paths=()

        # Markdown链接
        while [[ "$line" =~ \[([^\]]+)\]\(([^\)]+)\) ]]; do
            local link="${BASH_REMATCH[2]}"
            # 跳过URL
            if [[ ! "$link" =~ ^https?:// ]] && [[ ! "$link" =~ ^# ]]; then
                paths+=("$link")
            fi
            line="${line#*\]}"
        done

        # 代码块中的路径
        while [[ "$line" =~ \`([^\`]+)\` ]]; do
            local code="${BASH_REMATCH[1]}"
            if [[ "$code" =~ ^(scripts|tools|config|tests|docs)/[^[:space:]]+ ]]; then
                paths+=("$code")
            fi
            line="${line#*\`}"
        done

        # 直接路径引用
        if [[ "$line" =~ (scripts|tools|config|tests|docs)/[^[:space:],\)]+\.(sh|py|yaml|yml|env|md) ]]; then
            paths+=("${BASH_REMATCH[0]}")
        fi

        # 检查每个路径是否存在
        for path in "${paths[@]}"; do
            # 移除可能的引号和空格
            path="${path//\"/}"
            path="${path//\'/}"
            path="${path// /}"

            # 跳过空路径
            [[ -z "$path" ]] && continue

            # 检查文件是否存在
            if [[ ! -f "${ROOT_DIR}/${path}" ]] && [[ ! -d "${ROOT_DIR}/${path}" ]]; then
                issues+=("引用的文件不存在: ${path}")
            fi
        done
    done < "$doc_file"

    printf '%s\n' "${issues[@]}"
}

# 检查文档中的命令示例是否有效
check_command_examples() {
    local doc_file="$1"
    local issues=()
    local in_code_block=0
    local code_block_lang=""

    while IFS= read -r line; do
        # 检测代码块开始
        if [[ "$line" =~ ^\`\`\`([a-z]*) ]]; then
            if [[ $in_code_block -eq 0 ]]; then
                in_code_block=1
                code_block_lang="${BASH_REMATCH[1]}"
            else
                in_code_block=0
                code_block_lang=""
            fi
            continue
        fi

        # 在bash/shell代码块中检查命令
        if [[ $in_code_block -eq 1 ]] && [[ "$code_block_lang" =~ ^(bash|shell|sh)?$ ]]; then
            # 跳过注释和空行
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// /}" ]] && continue

            # 检查脚本调用
            if [[ "$line" =~ (scripts|tools)/[^[:space:]]+\.sh ]]; then
                local script="${BASH_REMATCH[0]}"
                if [[ ! -f "${ROOT_DIR}/${script}" ]]; then
                    issues+=("命令示例中的脚本不存在: ${script}")
                fi
            fi
        fi
    done < "$doc_file"

    printf '%s\n' "${issues[@]}"
}

# 检查中英文文档的一致性
check_bilingual_consistency() {
    local issues=()

    # 检查README
    if [[ -f "${ROOT_DIR}/README.md" ]] && [[ -f "${ROOT_DIR}/README_EN.md" ]]; then
        local cn_lines
        cn_lines=$(wc -l < "${ROOT_DIR}/README.md")
        local en_lines
        en_lines=$(wc -l < "${ROOT_DIR}/README_EN.md")

        # 如果行数差异超过20%，可能不一致
        local diff=$(( (cn_lines - en_lines) * 100 / cn_lines ))
        if [[ ${diff#-} -gt 20 ]]; then
            issues+=("README.md 和 README_EN.md 行数差异较大 (${cn_lines} vs ${en_lines})")
        fi
    fi

    # 检查其他成对的中英文文档
    while IFS= read -r -d '' cn_doc; do
        local en_doc="${cn_doc%.md}_EN.md"
        if [[ -f "$en_doc" ]]; then
            local cn_lines
            cn_lines=$(wc -l < "$cn_doc")
            local en_lines
            en_lines=$(wc -l < "$en_doc")

            local diff=$(( (cn_lines - en_lines) * 100 / cn_lines ))
            if [[ ${diff#-} -gt 20 ]]; then
                local relative_cn="${cn_doc#${ROOT_DIR}/}"
                local relative_en="${en_doc#${ROOT_DIR}/}"
                issues+=("${relative_cn} 和 ${relative_en} 行数差异较大 (${cn_lines} vs ${en_lines})")
            fi
        fi
    done < <(find "${ROOT_DIR}/docs" -type f -name "*.md" ! -name "*_EN.md" -print0 2>/dev/null || true)

    printf '%s\n' "${issues[@]}"
}

# 检查文档的最后修改时间
check_doc_freshness() {
    local doc_file="$1"
    local status="fresh"
    local reason=""

    local last_modified
    last_modified=$(git log -1 --format="%ai" -- "$doc_file" 2>/dev/null || echo "unknown")

    if [[ "$last_modified" != "unknown" ]]; then
        local last_modified_epoch
        last_modified_epoch=$(date -d "$last_modified" +%s 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local days_ago=$(( (now_epoch - last_modified_epoch) / 86400 ))

        if [[ $days_ago -gt 180 ]]; then
            status="stale"
            reason="超过6个月未更新"
        elif [[ $days_ago -gt 90 ]]; then
            status="aging"
            reason="超过3个月未更新"
        fi
    fi

    echo "${status}|${reason}|${last_modified}"
}

# 主函数
main() {
    log_info "开始检查文档一致性..."
    log_info "项目根目录: ${ROOT_DIR}"
    log_info "输出文件: ${OUTPUT_FILE}"

    # 收集文档文件
    local doc_files
    doc_files=($(collect_doc_files))
    log_info "找到 ${#doc_files[@]} 个文档文件"

    # 分析每个文档
    declare -A doc_issues
    declare -A doc_freshness

    for doc_file in "${doc_files[@]}"; do
        local relative_path="${doc_file#${ROOT_DIR}/}"
        if [[ $VERBOSE -eq 1 ]]; then
            log_info "检查文档: ${relative_path}"
        fi

        # 检查文件引用
        local file_ref_issues
        file_ref_issues=$(check_file_references "$doc_file")

        # 检查命令示例
        local cmd_issues
        cmd_issues=$(check_command_examples "$doc_file")

        # 合并问题
        local all_issues=""
        [[ -n "$file_ref_issues" ]] && all_issues="${all_issues}${file_ref_issues}"$'\n'
        [[ -n "$cmd_issues" ]] && all_issues="${all_issues}${cmd_issues}"$'\n'

        if [[ -n "$all_issues" ]]; then
            doc_issues["$relative_path"]="$all_issues"
        fi

        # 检查文档新鲜度
        local freshness
        freshness=$(check_doc_freshness "$doc_file")
        doc_freshness["$relative_path"]="$freshness"
    done

    # 检查中英文一致性
    local bilingual_issues
    bilingual_issues=$(check_bilingual_consistency)

    # 生成报告
    generate_report

    log_info "检查完成！报告已保存到: ${OUTPUT_FILE}"
}

# 生成报告
generate_report() {
    cat > "$OUTPUT_FILE" <<EOF
# 文档一致性检查报告

**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
**检查范围**: 项目所有Markdown文档

## 执行摘要

- **文档总数**: ${#doc_files[@]}
- **有问题的文档**: ${#doc_issues[@]}
- **过时文档**: $(count_by_status "stale")
- **老化文档**: $(count_by_status "aging")

## 文档问题列表

### 文件引用和命令错误

EOF

    if [[ ${#doc_issues[@]} -eq 0 ]]; then
        echo "未发现文件引用或命令错误。" >> "$OUTPUT_FILE"
    else
        for doc in "${!doc_issues[@]}"; do
            echo "#### ${doc}" >> "$OUTPUT_FILE"
            echo "" >> "$OUTPUT_FILE"
            echo "${doc_issues[$doc]}" | while IFS= read -r issue; do
                [[ -n "$issue" ]] && echo "- ${issue}" >> "$OUTPUT_FILE"
            done
            echo "" >> "$OUTPUT_FILE"
        done
    fi

    cat >> "$OUTPUT_FILE" <<EOF

### 中英文文档一致性

EOF

    if [[ -z "$bilingual_issues" ]]; then
        echo "中英文文档基本一致。" >> "$OUTPUT_FILE"
    else
        echo "$bilingual_issues" | while IFS= read -r issue; do
            [[ -n "$issue" ]] && echo "- ${issue}" >> "$OUTPUT_FILE"
        done
    fi

    cat >> "$OUTPUT_FILE" <<EOF

## 文档新鲜度分析

### 过时文档（超过6个月未更新）

| 文档路径 | 最后更新时间 | 原因 |
|---------|------------|------|
EOF

    for doc in "${!doc_freshness[@]}"; do
        local status reason last_modified
        IFS='|' read -r status reason last_modified <<< "${doc_freshness[$doc]}"
        if [[ "$status" == "stale" ]]; then
            echo "| ${doc} | ${last_modified} | ${reason} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

### 老化文档（超过3个月未更新）

| 文档路径 | 最后更新时间 | 原因 |
|---------|------------|------|
EOF

    for doc in "${!doc_freshness[@]}"; do
        local status reason last_modified
        IFS='|' read -r status reason last_modified <<< "${doc_freshness[$doc]}"
        if [[ "$status" == "aging" ]]; then
            echo "| ${doc} | ${last_modified} | ${reason} |" >> "$OUTPUT_FILE"
        fi
    done

    cat >> "$OUTPUT_FILE" <<EOF

## 修复建议

### 高优先级
1. 修复文件引用错误（${#doc_issues[@]}个文档）
2. 更新过时文档（$(count_by_status "stale")个文档）
3. 同步中英文文档内容

### 中优先级
1. 审查老化文档（$(count_by_status "aging")个文档）
2. 验证命令示例的有效性
3. 补充缺失的文档

### 低优先级
1. 统一文档格式和风格
2. 添加更多示例和图表
3. 改进文档导航结构

## 文档维护建议

1. **定期更新**: 每次代码变更后同步更新相关文档
2. **双语同步**: 中英文文档应同时更新
3. **示例验证**: 定期运行文档中的命令示例，确保有效
4. **版本标记**: 在文档中标注版本号和更新日期
5. **自动化检查**: 将文档一致性检查集成到CI/CD流程

---
**报告生成工具**: tools/evaluation/check_docs.sh
**版本**: 1.0
EOF
}

# 辅助函数：按状态统计文档数量
count_by_status() {
    local target_status="$1"
    local count=0

    for doc in "${!doc_freshness[@]}"; do
        local status
        status=$(echo "${doc_freshness[$doc]}" | cut -d'|' -f1)
        if [[ "$status" == "$target_status" ]]; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

# 执行主函数
main "$@"
