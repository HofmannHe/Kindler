#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 项目清理脚本
# 根据评估报告执行清理操作，支持预览模式

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
EVAL_DIR="${ROOT_DIR}/docs/evaluation"
ARCHIVE_DIR="${ROOT_DIR}/archive"
LOG_FILE="${ROOT_DIR}/logs/cleanup_$(date +%Y%m%d_%H%M%S).log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() {
    local msg="[INFO] $*"
    echo -e "${GREEN}${msg}${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
}

log_warn() {
    local msg="[WARN] $*"
    echo -e "${YELLOW}${msg}${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
}

log_error() {
    local msg="[ERROR] $*"
    echo -e "${RED}${msg}${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
}

log_action() {
    local msg="[ACTION] $*"
    echo -e "${BLUE}${msg}${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
}

# 显示帮助信息
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

项目清理工具 - 根据评估报告执行清理操作

OPTIONS:
    -h, --help              显示此帮助信息
    --dry-run               预览模式，仅显示将要执行的操作
    --execute               执行实际清理操作
    --interactive           交互式确认每个操作
    --whitelist FILE        指定白名单文件（不删除的文件列表）
    --backup-tag TAG        创建Git tag作为备份点 (默认: cleanup-backup-YYYYMMDD)

EXAMPLES:
    $(basename "$0") --dry-run          # 预览清理操作
    $(basename "$0") --execute          # 执行清理操作
    $(basename "$0") --interactive      # 交互式清理

NOTES:
    - 默认为预览模式（--dry-run）
    - 执行模式会自动创建Git tag备份
    - 白名单文件每行一个文件路径

EOF
}

# 解析命令行参数
DRY_RUN=1
INTERACTIVE=0
WHITELIST_FILE=""
BACKUP_TAG="cleanup-backup-$(date +%Y%m%d)"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --execute)
            DRY_RUN=0
            shift
            ;;
        --interactive)
            INTERACTIVE=1
            shift
            ;;
        --whitelist)
            WHITELIST_FILE="$2"
            shift 2
            ;;
        --backup-tag)
            BACKUP_TAG="$2"
            shift 2
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

# 加载白名单
declare -A WHITELIST
if [[ -n "$WHITELIST_FILE" ]] && [[ -f "$WHITELIST_FILE" ]]; then
    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        WHITELIST["$line"]=1
    done < "$WHITELIST_FILE"
    log_info "加载白名单: ${#WHITELIST[@]} 个文件"
fi

# 检查文件是否在白名单中
is_whitelisted() {
    local file="$1"
    [[ -n "${WHITELIST[$file]:-}" ]]
}

# 创建备份tag
create_backup_tag() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] 将创建Git tag: ${BACKUP_TAG}"
        return 0
    fi

    log_action "创建Git tag备份: ${BACKUP_TAG}"
    if git tag -a "$BACKUP_TAG" -m "Backup before cleanup on $(date '+%Y-%m-%d %H:%M:%S')"; then
        log_info "Git tag创建成功: ${BACKUP_TAG}"
        log_info "如需回滚，运行: git reset --hard ${BACKUP_TAG}"
    else
        log_error "Git tag创建失败"
        return 1
    fi
}

# 删除文件
delete_file() {
    local file="$1"
    local reason="$2"

    # 检查白名单
    if is_whitelisted "$file"; then
        log_warn "跳过白名单文件: ${file}"
        return 0
    fi

    # 交互式确认
    if [[ $INTERACTIVE -eq 1 ]]; then
        echo -n "删除 ${file} (原因: ${reason})? [y/N] "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "跳过: ${file}"
            return 0
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log_action "[DRY-RUN] 删除: ${file} (原因: ${reason})"
    else
        log_action "删除: ${file} (原因: ${reason})"
        if rm -f "${ROOT_DIR}/${file}"; then
            log_info "已删除: ${file}"
        else
            log_error "删除失败: ${file}"
            return 1
        fi
    fi
}

# 归档文件
archive_file() {
    local file="$1"
    local reason="$2"

    # 检查白名单
    if is_whitelisted "$file"; then
        log_warn "跳过白名单文件: ${file}"
        return 0
    fi

    local archive_path="${ARCHIVE_DIR}/${file}"
    local archive_dir
    archive_dir="$(dirname "$archive_path")"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_action "[DRY-RUN] 归档: ${file} -> ${archive_path} (原因: ${reason})"
    else
        log_action "归档: ${file} -> ${archive_path} (原因: ${reason})"
        mkdir -p "$archive_dir"
        if mv "${ROOT_DIR}/${file}" "$archive_path"; then
            # 创建元数据文件
            cat > "${archive_path}.meta" <<EOF
原始路径: ${file}
归档时间: $(date '+%Y-%m-%d %H:%M:%S')
归档原因: ${reason}
Git commit: $(git rev-parse HEAD)
EOF
            log_info "已归档: ${file}"
        else
            log_error "归档失败: ${file}"
            return 1
        fi
    fi
}

# 清理冗余代码文件
cleanup_redundant_code() {
    log_info "========================================="
    log_info "清理冗余代码文件"
    log_info "========================================="

    local code_report="${EVAL_DIR}/code_usage_report.md"
    if [[ ! -f "$code_report" ]]; then
        log_warn "代码使用报告不存在，跳过"
        return 0
    fi

    # 提取冗余文件列表
    local in_redundant_section=0
    while IFS= read -r line; do
        if [[ "$line" == "## 冗余文件列表（建议删除）" ]]; then
            in_redundant_section=1
            continue
        elif [[ "$line" =~ ^## ]] && [[ $in_redundant_section -eq 1 ]]; then
            break
        fi

        if [[ $in_redundant_section -eq 1 ]] && [[ "$line" =~ ^\|[[:space:]]*([^|]+)[[:space:]]*\| ]]; then
            local file="${BASH_REMATCH[1]}"
            file="${file// /}"  # 移除空格
            # 跳过表头
            [[ "$file" == "文件路径" ]] && continue
            [[ "$file" == "---" ]] && continue
            [[ -z "$file" ]] && continue

            delete_file "$file" "冗余文件（超过6个月未修改且无引用）"
        fi
    done < "$code_report"
}

# 清理运行时产物
cleanup_runtime_artifacts() {
    log_info "========================================="
    log_info "清理运行时产物"
    log_info "========================================="

    # 清理根目录的日志文件
    local root_logs=(
        "full_regression_final.log"
        "full_regression_test.log"
        "webui_e2e_final_test.log"
        "webui_e2e_test_fixed.log"
        "webui_e2e_test.log"
    )

    for log in "${root_logs[@]}"; do
        if [[ -f "${ROOT_DIR}/${log}" ]]; then
            delete_file "$log" "根目录运行时日志"
        fi
    done

    # 清理过期的回归测试日志（保留最近5次）
    log_info "清理过期的回归测试日志（保留最近5次）..."
    local regression_logs_dir="${ROOT_DIR}/logs/regression"
    if [[ -d "$regression_logs_dir" ]]; then
        local log_dirs
        log_dirs=($(find "$regression_logs_dir" -maxdepth 1 -type d -name "202*" | sort -r))

        if [[ ${#log_dirs[@]} -gt 5 ]]; then
            local to_delete=("${log_dirs[@]:5}")
            for dir in "${to_delete[@]}"; do
                local relative_dir="${dir#${ROOT_DIR}/}"
                if [[ $DRY_RUN -eq 1 ]]; then
                    log_action "[DRY-RUN] 删除目录: ${relative_dir}"
                else
                    log_action "删除目录: ${relative_dir}"
                    rm -rf "$dir"
                    log_info "已删除: ${relative_dir}"
                fi
            done
        else
            log_info "回归测试日志数量未超过阈值，无需清理"
        fi
    fi
}

# 生成清理摘要
generate_summary() {
    log_info "========================================="
    log_info "清理摘要"
    log_info "========================================="

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "模式: 预览模式（未执行实际操作）"
    else
        log_info "模式: 执行模式"
    fi

    log_info "日志文件: ${LOG_FILE}"

    if [[ $DRY_RUN -eq 0 ]]; then
        log_info "备份tag: ${BACKUP_TAG}"
        log_info "归档目录: ${ARCHIVE_DIR}"
    fi

    echo ""
    log_info "详细日志请查看: ${LOG_FILE}"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo ""
        log_info "要执行实际清理，请运行:"
        log_info "  $(basename "$0") --execute"
    fi
}

# 主函数
main() {
    log_info "项目清理工具"
    log_info "项目根目录: ${ROOT_DIR}"
    log_info "评估报告目录: ${EVAL_DIR}"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warn "运行在预览模式，不会执行实际操作"
    else
        log_warn "运行在执行模式，将执行实际清理操作"
        # 创建备份tag
        if ! create_backup_tag; then
            log_error "备份创建失败，中止清理"
            exit 1
        fi
    fi

    echo ""

    # 执行清理操作
    cleanup_redundant_code
    echo ""
    cleanup_runtime_artifacts
    echo ""

    # 生成摘要
    generate_summary
}

# 执行主函数
main "$@"
