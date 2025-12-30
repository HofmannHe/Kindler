#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 依赖关系映射工具
# 分析项目中文件之间的依赖关系，生成依赖关系图

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/docs/evaluation"
OUTPUT_MD="${OUTPUT_DIR}/dependency_graph.md"
OUTPUT_DOT="${OUTPUT_DIR}/dependency_graph.dot"

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

依赖关系映射工具 - 分析项目中文件之间的依赖关系

OPTIONS:
    -h, --help              显示此帮助信息
    -o, --output DIR        指定输出目录 (默认: ${OUTPUT_DIR})
    -v, --verbose           详细输出模式
    --module PATH           仅分析指定模块 (如: scripts/)
    --format FORMAT         输出格式: text|dot|both (默认: both)

EXAMPLES:
    $(basename "$0")                    # 分析整个项目
    $(basename "$0") --module scripts/  # 仅分析scripts目录
    $(basename "$0") --format dot       # 仅生成DOT格式

EOF
}

# 解析命令行参数
VERBOSE=0
MODULE_FILTER=""
OUTPUT_FORMAT="both"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            OUTPUT_MD="${OUTPUT_DIR}/dependency_graph.md"
            OUTPUT_DOT="${OUTPUT_DIR}/dependency_graph.dot"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --module)
            MODULE_FILTER="$2"
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
mkdir -p "$OUTPUT_DIR"

# 依赖关系数据结构
declare -A DEPENDENCIES  # key: file, value: space-separated list of dependencies
declare -A REVERSE_DEPS  # key: file, value: space-separated list of files that depend on it
declare -A FILE_TYPE     # key: file, value: type (script|config|doc)

# 分析Shell脚本依赖
analyze_shell_dependencies() {
    local file="$1"
    local relative_path="${file#${ROOT_DIR}/}"

    # 查找source语句
    local deps=""
    while IFS= read -r line; do
        # 匹配 source path 或 . path
        if [[ "$line" =~ source[[:space:]]+([^[:space:]]+) ]] || [[ "$line" =~ ^[[:space:]]*\.[[:space:]]+([^[:space:]]+) ]]; then
            local dep="${BASH_REMATCH[1]}"
            # 移除引号
            dep="${dep//\"/}"
            dep="${dep//\'/}"

            # 处理相对路径
            if [[ "$dep" == \$* ]]; then
                # 跳过变量引用
                continue
            elif [[ "$dep" == /* ]]; then
                # 绝对路径
                dep="${dep#${ROOT_DIR}/}"
            else
                # 相对路径
                local dir
                dir="$(dirname "$file")"
                dep="$(cd "$dir" && realpath --relative-to="$ROOT_DIR" "$dep" 2>/dev/null || echo "$dep")"
            fi

            # 检查文件是否存在
            if [[ -f "${ROOT_DIR}/${dep}" ]]; then
                deps="${deps} ${dep}"
            fi
        fi
    done < "$file"

    if [[ -n "$deps" ]]; then
        DEPENDENCIES["$relative_path"]="$deps"
        for dep in $deps; do
            REVERSE_DEPS["$dep"]="${REVERSE_DEPS[$dep]:-} ${relative_path}"
        done
    fi

    FILE_TYPE["$relative_path"]="script"
}

# 分析YAML配置依赖
analyze_yaml_dependencies() {
    local file="$1"
    local relative_path="${file#${ROOT_DIR}/}"

    # 查找文件引用（简化版）
    local deps=""
    while IFS= read -r line; do
        # 匹配常见的文件引用模式
        if [[ "$line" =~ (file|path|script):[[:space:]]*([^[:space:]]+) ]]; then
            local dep="${BASH_REMATCH[2]}"
            dep="${dep//\"/}"
            dep="${dep//\'/}"

            if [[ -f "${ROOT_DIR}/${dep}" ]]; then
                deps="${deps} ${dep}"
            fi
        fi
    done < "$file"

    if [[ -n "$deps" ]]; then
        DEPENDENCIES["$relative_path"]="$deps"
        for dep in $deps; do
            REVERSE_DEPS["$dep"]="${REVERSE_DEPS[$dep]:-} ${relative_path}"
        done
    fi

    FILE_TYPE["$relative_path"]="config"
}

# 收集所有文件
collect_files() {
    local files=()
    local search_path="${ROOT_DIR}"

    if [[ -n "$MODULE_FILTER" ]]; then
        search_path="${ROOT_DIR}/${MODULE_FILTER}"
    fi

    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$search_path" -type f \( -name "*.sh" -o -name "*.yaml" -o -name "*.yml" \) \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        ! -path "*/venv/*" \
        ! -path "*/archive/*" \
        ! -path "*/worktrees/*" \
        -print0)

    echo "${files[@]}"
}

# 分析依赖关系
analyze_dependencies() {
    log_info "开始分析依赖关系..."

    local files
    files=($(collect_files))
    log_info "找到 ${#files[@]} 个文件"

    local count=0
    for file in "${files[@]}"; do
        count=$((count + 1))
        if [[ $VERBOSE -eq 1 ]]; then
            log_info "分析 [${count}/${#files[@]}]: ${file#${ROOT_DIR}/}"
        fi

        case "$file" in
            *.sh)
                analyze_shell_dependencies "$file"
                ;;
            *.yaml|*.yml)
                analyze_yaml_dependencies "$file"
                ;;
        esac
    done

    log_info "依赖关系分析完成"
}

# 识别孤立文件和核心文件
identify_special_files() {
    local isolated=()
    local core=()

    for file in "${!FILE_TYPE[@]}"; do
        local in_degree=0
        local out_degree=0

        # 计算入度（被多少文件依赖）
        if [[ -n "${REVERSE_DEPS[$file]:-}" ]]; then
            in_degree=$(echo "${REVERSE_DEPS[$file]}" | wc -w)
        fi

        # 计算出度（依赖多少文件）
        if [[ -n "${DEPENDENCIES[$file]:-}" ]]; then
            out_degree=$(echo "${DEPENDENCIES[$file]}" | wc -w)
        fi

        # 孤立文件：入度和出度都为0
        if [[ $in_degree -eq 0 ]] && [[ $out_degree -eq 0 ]]; then
            isolated+=("$file")
        fi

        # 核心文件：入度 >= 3
        if [[ $in_degree -ge 3 ]]; then
            core+=("$file|$in_degree")
        fi
    done

    echo "ISOLATED:${isolated[*]}"
    echo "CORE:${core[*]}"
}

# 生成Markdown报告
generate_markdown_report() {
    log_info "生成Markdown报告..."

    local special_files
    special_files=$(identify_special_files)
    local isolated
    isolated=$(echo "$special_files" | grep "^ISOLATED:" | cut -d: -f2)
    local core
    core=$(echo "$special_files" | grep "^CORE:" | cut -d: -f2)

    cat > "$OUTPUT_MD" <<EOF
# 依赖关系分析报告

**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
**分析范围**: ${MODULE_FILTER:-整个项目}

## 执行摘要

- **总文件数**: ${#FILE_TYPE[@]}
- **有依赖关系的文件**: ${#DEPENDENCIES[@]}
- **孤立文件**: $(echo "$isolated" | wc -w)
- **核心文件**: $(echo "$core" | wc -w)

## 孤立文件列表

孤立文件是指既不依赖其他文件，也不被其他文件依赖的文件。这些文件可能是：
- 独立的工具脚本
- 废弃的代码
- 新增但未集成的功能

| 文件路径 | 类型 |
|---------|------|
EOF

    for file in $isolated; do
        echo "| ${file} | ${FILE_TYPE[$file]} |" >> "$OUTPUT_MD"
    done

    cat >> "$OUTPUT_MD" <<EOF

## 核心文件列表

核心文件是被多个其他文件依赖的关键文件，删除风险高。

| 文件路径 | 被依赖次数 | 类型 |
|---------|-----------|------|
EOF

    for item in $core; do
        local file
        file=$(echo "$item" | cut -d'|' -f1)
        local count
        count=$(echo "$item" | cut -d'|' -f2)
        echo "| ${file} | ${count} | ${FILE_TYPE[$file]} |" >> "$OUTPUT_MD"
    done

    cat >> "$OUTPUT_MD" <<EOF

## 依赖关系详情

### 文件依赖列表

EOF

    for file in "${!DEPENDENCIES[@]}"; do
        echo "#### ${file}" >> "$OUTPUT_MD"
        echo "" >> "$OUTPUT_MD"
        echo "**依赖的文件**:" >> "$OUTPUT_MD"
        for dep in ${DEPENDENCIES[$file]}; do
            echo "- ${dep}" >> "$OUTPUT_MD"
        done
        echo "" >> "$OUTPUT_MD"

        if [[ -n "${REVERSE_DEPS[$file]:-}" ]]; then
            echo "**被以下文件依赖**:" >> "$OUTPUT_MD"
            for rdep in ${REVERSE_DEPS[$file]}; do
                echo "- ${rdep}" >> "$OUTPUT_MD"
            done
            echo "" >> "$OUTPUT_MD"
        fi
    done

    cat >> "$OUTPUT_MD" <<EOF

## 清理建议

### 可安全删除的文件
- 孤立文件中的废弃代码（需人工确认）

### 需谨慎处理的文件
- 核心文件：删除会影响多个模块
- 有依赖关系的文件：需要同时更新依赖方

### 重构建议
- 考虑将核心文件拆分，降低耦合度
- 为孤立的工具脚本添加文档说明

---
**报告生成工具**: tools/evaluation/analyze_dependencies.sh
**版本**: 1.0
EOF

    log_info "Markdown报告已保存到: ${OUTPUT_MD}"
}

# 生成DOT格式图
generate_dot_graph() {
    log_info "生成DOT格式依赖图..."

    cat > "$OUTPUT_DOT" <<EOF
digraph dependencies {
    rankdir=LR;
    node [shape=box, style=rounded];

    // 节点定义
EOF

    # 定义节点（根据类型设置颜色）
    for file in "${!FILE_TYPE[@]}"; do
        local color="lightblue"
        case "${FILE_TYPE[$file]}" in
            script) color="lightgreen" ;;
            config) color="lightyellow" ;;
        esac

        # 转义特殊字符
        local safe_file
        safe_file="${file//\//\\/}"
        echo "    \"${safe_file}\" [fillcolor=${color}, style=filled];" >> "$OUTPUT_DOT"
    done

    cat >> "$OUTPUT_DOT" <<EOF

    // 依赖关系
EOF

    # 定义边
    for file in "${!DEPENDENCIES[@]}"; do
        local safe_file
        safe_file="${file//\//\\/}"
        for dep in ${DEPENDENCIES[$file]}; do
            local safe_dep
            safe_dep="${dep//\//\\/}"
            echo "    \"${safe_file}\" -> \"${safe_dep}\";" >> "$OUTPUT_DOT"
        done
    done

    echo "}" >> "$OUTPUT_DOT"

    log_info "DOT图已保存到: ${OUTPUT_DOT}"
    log_info "可使用以下命令生成PNG图片:"
    log_info "  dot -Tpng ${OUTPUT_DOT} -o ${OUTPUT_DIR}/dependency_graph.png"
}

# 主函数
main() {
    log_info "依赖关系映射工具"
    log_info "项目根目录: ${ROOT_DIR}"
    log_info "输出目录: ${OUTPUT_DIR}"

    # 分析依赖关系
    analyze_dependencies

    # 生成报告
    case "$OUTPUT_FORMAT" in
        text)
            generate_markdown_report
            ;;
        dot)
            generate_dot_graph
            ;;
        both)
            generate_markdown_report
            generate_dot_graph
            ;;
        *)
            log_error "不支持的输出格式: $OUTPUT_FORMAT"
            exit 1
            ;;
    esac

    log_info "分析完成！"
}

# 执行主函数
main "$@"
