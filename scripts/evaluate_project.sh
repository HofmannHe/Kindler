#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 项目评估主入口脚本
# 运行所有评估工具并生成综合报告

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/tools/evaluation"
OUTPUT_DIR="${ROOT_DIR}/docs/evaluation"
REPORT_FILE="${ROOT_DIR}/docs/PROJECT_EVALUATION_REPORT.md"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

# 显示帮助信息
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

项目评估工具 - 运行所有评估工具并生成综合报告

OPTIONS:
    -h, --help              显示此帮助信息
    -o, --output FILE       指定输出文件路径 (默认: ${REPORT_FILE})
    -v, --verbose           详细输出模式
    --skip-code             跳过代码使用分析
    --skip-deps             跳过依赖关系映射
    --skip-coverage         跳过测试覆盖率评估
    --skip-docs             跳过文档一致性检查

EXAMPLES:
    $(basename "$0")                    # 运行完整评估
    $(basename "$0") -v                 # 详细输出模式
    $(basename "$0") --skip-coverage    # 跳过测试覆盖率评估

EOF
}

# 解析命令行参数
VERBOSE=0
SKIP_CODE=0
SKIP_DEPS=0
SKIP_COVERAGE=0
SKIP_DOCS=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -o|--output)
            REPORT_FILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --skip-code)
            SKIP_CODE=1
            shift
            ;;
        --skip-deps)
            SKIP_DEPS=1
            shift
            ;;
        --skip-coverage)
            SKIP_COVERAGE=1
            shift
            ;;
        --skip-docs)
            SKIP_DOCS=1
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
mkdir -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$REPORT_FILE")"

# 运行评估工具
run_evaluation() {
    local start_time
    start_time=$(date +%s)

    log_info "========================================="
    log_info "开始项目评估"
    log_info "========================================="
    log_info "项目根目录: ${ROOT_DIR}"
    log_info "输出目录: ${OUTPUT_DIR}"
    log_info "综合报告: ${REPORT_FILE}"
    echo ""

    # 1. 代码使用分析
    if [[ $SKIP_CODE -eq 0 ]]; then
        log_step "1/4 运行代码使用分析..."
        local verbose_flag=""
        [[ $VERBOSE -eq 1 ]] && verbose_flag="-v"
        if "${TOOLS_DIR}/analyze_code.sh" $verbose_flag; then
            log_info "代码使用分析完成"
        else
            log_error "代码使用分析失败"
            return 1
        fi
        echo ""
    else
        log_warn "跳过代码使用分析"
    fi

    # 2. 依赖关系映射
    if [[ $SKIP_DEPS -eq 0 ]]; then
        log_step "2/4 运行依赖关系映射..."
        local verbose_flag=""
        [[ $VERBOSE -eq 1 ]] && verbose_flag="-v"
        if "${TOOLS_DIR}/analyze_dependencies.sh" $verbose_flag; then
            log_info "依赖关系映射完成"
        else
            log_error "依赖关系映射失败"
            return 1
        fi
        echo ""
    else
        log_warn "跳过依赖关系映射"
    fi

    # 3. 测试覆盖率评估
    if [[ $SKIP_COVERAGE -eq 0 ]]; then
        log_step "3/4 运行测试覆盖率评估..."
        local verbose_flag=""
        [[ $VERBOSE -eq 1 ]] && verbose_flag="-v"
        if "${TOOLS_DIR}/analyze_coverage.sh" $verbose_flag; then
            log_info "测试覆盖率评估完成"
        else
            log_error "测试覆盖率评估失败"
            return 1
        fi
        echo ""
    else
        log_warn "跳过测试覆盖率评估"
    fi

    # 4. 文档一致性检查
    if [[ $SKIP_DOCS -eq 0 ]]; then
        log_step "4/4 运行文档一致性检查..."
        local verbose_flag=""
        [[ $VERBOSE -eq 1 ]] && verbose_flag="-v"
        if "${TOOLS_DIR}/check_docs.sh" $verbose_flag; then
            log_info "文档一致性检查完成"
        else
            log_error "文档一致性检查失败"
            return 1
        fi
        echo ""
    else
        log_warn "跳过文档一致性检查"
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "所有评估工具运行完成（耗时: ${duration}秒）"
    return 0
}

# 生成综合报告
generate_comprehensive_report() {
    log_step "生成综合评估报告..."

    cat > "$REPORT_FILE" <<EOF
# Kindler 项目评估综合报告

**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
**评估范围**: 整个项目
**评估工具版本**: 1.0

---

## 执行摘要

本报告汇总了项目的代码质量、依赖关系、测试覆盖率和文档一致性评估结果。

### 关键发现

EOF

    # 提取关键指标
    local code_report="${OUTPUT_DIR}/code_usage_report.md"
    local deps_report="${OUTPUT_DIR}/dependency_graph.md"
    local coverage_report="${OUTPUT_DIR}/test_coverage_report.md"
    local docs_report="${OUTPUT_DIR}/doc_consistency_report.md"

    # 代码使用情况
    if [[ -f "$code_report" ]]; then
        echo "#### 代码使用情况" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        grep -A 6 "^## 执行摘要" "$code_report" | tail -n +2 >> "$REPORT_FILE" || echo "- 数据提取失败" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi

    # 依赖关系
    if [[ -f "$deps_report" ]]; then
        echo "#### 依赖关系" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        grep -A 4 "^## 执行摘要" "$deps_report" | tail -n +2 >> "$REPORT_FILE" || echo "- 数据提取失败" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi

    # 测试覆盖率
    if [[ -f "$coverage_report" ]]; then
        echo "#### 测试覆盖率" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        grep -A 5 "^## 执行摘要" "$coverage_report" | tail -n +2 >> "$REPORT_FILE" || echo "- 数据提取失败" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi

    # 文档一致性
    if [[ -f "$docs_report" ]]; then
        echo "#### 文档一致性" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        grep -A 4 "^## 执行摘要" "$docs_report" | tail -n +2 >> "$REPORT_FILE" || echo "- 数据提取失败" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" <<EOF

---

## 详细报告

### 1. 代码使用情况分析

详细报告请查看: [code_usage_report.md](evaluation/code_usage_report.md)

**主要发现**:
EOF

    if [[ -f "$code_report" ]]; then
        echo "" >> "$REPORT_FILE"
        grep -A 2 "^**清理建议**:" "$code_report" >> "$REPORT_FILE" || echo "- 无特殊发现" >> "$REPORT_FILE"
    else
        echo "- 报告未生成" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" <<EOF

### 2. 依赖关系映射

详细报告请查看: [dependency_graph.md](evaluation/dependency_graph.md)

**主要发现**:
EOF

    if [[ -f "$deps_report" ]]; then
        echo "" >> "$REPORT_FILE"
        grep -A 10 "^## 清理建议" "$deps_report" | head -n 8 >> "$REPORT_FILE" || echo "- 无特殊发现" >> "$REPORT_FILE"
    else
        echo "- 报告未生成" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" <<EOF

### 3. 测试覆盖率评估

详细报告请查看: [test_coverage_report.md](evaluation/test_coverage_report.md)

**主要发现**:
EOF

    if [[ -f "$coverage_report" ]]; then
        echo "" >> "$REPORT_FILE"
        grep -A 10 "^## 改进建议" "$coverage_report" | head -n 8 >> "$REPORT_FILE" || echo "- 无特殊发现" >> "$REPORT_FILE"
    else
        echo "- 报告未生成" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" <<EOF

### 4. 文档一致性检查

详细报告请查看: [doc_consistency_report.md](evaluation/doc_consistency_report.md)

**主要发现**:
EOF

    if [[ -f "$docs_report" ]]; then
        echo "" >> "$REPORT_FILE"
        grep -A 10 "^## 修复建议" "$docs_report" | head -n 8 >> "$REPORT_FILE" || echo "- 无特殊发现" >> "$REPORT_FILE"
    else
        echo "- 报告未生成" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" <<EOF

---

## 清理优先级建议

基于以上评估结果，建议按以下优先级进行清理：

### 高优先级（立即执行）

1. **删除冗余文件**: 超过6个月未修改且无引用的文件
2. **修复文档错误**: 文档中引用的不存在文件
3. **清理运行时产物**: 根目录的日志文件和过期的回归测试日志

### 中优先级（1-2周内执行）

1. **合并重复测试**: 减少测试脚本数量，提高维护效率
2. **更新过时文档**: 超过6个月未更新的文档
3. **清理过时配置**: 未被使用的配置文件

### 低优先级（持续改进）

1. **提高测试覆盖率**: 为未覆盖的核心脚本添加测试
2. **优化依赖关系**: 降低核心文件的耦合度
3. **完善文档**: 补充缺失的文档和示例

---

## 风险评估

### 高风险操作

- 删除核心文件（被多个模块依赖）
- 修改入口脚本的接口
- 删除正在使用的配置文件

**缓解措施**:
- 删除前创建 Git tag 备份
- 使用归档机制而非直接删除
- 运行完整回归测试验证

### 中风险操作

- 合并测试脚本
- 更新依赖引用
- 重构公共库

**缓解措施**:
- 分阶段执行，每阶段验证
- 保持测试覆盖率不下降
- 提供迁移指南

### 低风险操作

- 清理日志文件
- 更新文档
- 删除孤立文件

**缓解措施**:
- 记录所有操作
- 保留归档副本

---

## 下一步行动

1. **审查报告**: 团队审查本报告，确认清理范围和优先级
2. **制定计划**: 基于优先级制定详细的清理计划
3. **创建备份**: 创建 Git tag 作为回滚点
4. **执行清理**: 按计划执行清理操作
5. **验证测试**: 运行完整回归测试验证功能
6. **更新文档**: 更新相关文档，记录变更

---

## 附录

### 评估工具列表

- **代码使用分析**: \`tools/evaluation/analyze_code.sh\`
- **依赖关系映射**: \`tools/evaluation/analyze_dependencies.sh\`
- **测试覆盖率评估**: \`tools/evaluation/analyze_coverage.sh\`
- **文档一致性检查**: \`tools/evaluation/check_docs.sh\`

### 相关文档

- [代码使用情况报告](evaluation/code_usage_report.md)
- [依赖关系图](evaluation/dependency_graph.md)
- [测试覆盖率报告](evaluation/test_coverage_report.md)
- [文档一致性报告](evaluation/doc_consistency_report.md)

---

**报告生成工具**: scripts/evaluate_project.sh
**版本**: 1.0
**联系人**: 项目技术负责人
EOF

    log_info "综合报告已生成: ${REPORT_FILE}"
}

# 主函数
main() {
    # 运行评估
    if ! run_evaluation; then
        log_error "评估过程中出现错误"
        exit 1
    fi

    # 生成综合报告
    generate_comprehensive_report

    echo ""
    log_info "========================================="
    log_info "项目评估完成！"
    log_info "========================================="
    log_info "综合报告: ${REPORT_FILE}"
    log_info "详细报告目录: ${OUTPUT_DIR}"
    echo ""
    log_info "请查看报告并制定清理计划"
}

# 执行主函数
main "$@"
