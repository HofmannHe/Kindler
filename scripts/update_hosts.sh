#!/usr/bin/env bash
# update_hosts.sh - 管理 /etc/hosts 文件中的 Kindler 环境域名记录
# 用法:
#   sudo ./scripts/update_hosts.sh --sync       # 同步所有环境到 hosts
#   sudo ./scripts/update_hosts.sh --add dev    # 添加单个环境
#   sudo ./scripts/update_hosts.sh --remove dev # 移除单个环境
#   sudo ./scripts/update_hosts.sh --clean      # 清理所有 Kindler 条目

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Kindler hosts 标记
HOSTS_MARKER_START="# BEGIN Kindler managed hosts"
HOSTS_MARKER_END="# END Kindler managed hosts"
HOSTS_FILE="/etc/hosts"

# 加载配置
load_config() {
    if [[ ! -f "${CONFIG_DIR}/clusters.env" ]]; then
        echo -e "${RED}错误: 找不到 ${CONFIG_DIR}/clusters.env${NC}" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/clusters.env"
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}" >&2
        echo "请使用: sudo $0 $*" >&2
        exit 1
    fi
}

# 备份 hosts 文件
backup_hosts() {
    local backup_file="${HOSTS_FILE}.kindler.$(date +%Y%m%d_%H%M%S).bak"
    cp "${HOSTS_FILE}" "${backup_file}"
    echo -e "${GREEN}已备份 hosts 文件到: ${backup_file}${NC}"
}

# 读取 CSV 环境列表
get_environments() {
    local csv_file="${CONFIG_DIR}/environments.csv"
    if [[ ! -f "${csv_file}" ]]; then
        echo -e "${RED}错误: 找不到 ${csv_file}${NC}" >&2
        exit 1
    fi

    # 读取 CSV (跳过注释和表头)
    grep -v '^#' "${csv_file}" | grep -v '^env,' | awk -F',' '{print $1}' | grep -v '^$'
}

# 生成单个环境的 hosts 条目
generate_host_entry() {
    local env="$1"
    local domain="${env}.${BASE_DOMAIN}"
    echo "${HAPROXY_HOST} ${domain}"
}

# 移除现有的 Kindler 条目
remove_kindler_entries() {
    if grep -q "${HOSTS_MARKER_START}" "${HOSTS_FILE}"; then
        # 使用 sed 删除标记之间的所有行（包括标记本身）
        sed -i.tmp "/${HOSTS_MARKER_START}/,/${HOSTS_MARKER_END}/d" "${HOSTS_FILE}"
        rm -f "${HOSTS_FILE}.tmp"
    fi
}

# 添加 Kindler 条目到 hosts
add_kindler_entries() {
    local entries=("$@")

    # 添加标记和条目
    {
        echo ""
        echo "${HOSTS_MARKER_START}"
        for entry in "${entries[@]}"; do
            echo "${entry}"
        done
        echo "${HOSTS_MARKER_END}"
    } >> "${HOSTS_FILE}"
}

# 同步所有环境
sync_all() {
    echo -e "${YELLOW}同步所有环境到 /etc/hosts...${NC}"

    load_config
    backup_hosts

    # 检查 BASE_DOMAIN 是否为 sslip.io 模式
    if [[ "${BASE_DOMAIN}" == *"sslip.io"* ]] || [[ "${BASE_DOMAIN}" == *"nip.io"* ]]; then
        echo -e "${YELLOW}警告: BASE_DOMAIN 使用了 sslip.io/nip.io，无需配置 hosts 文件${NC}"
        echo "如需使用本地域名，请将 BASE_DOMAIN 设置为 'local' 或自定义域名"
        exit 0
    fi

    local entries=()
    while IFS= read -r env; do
        entries+=("$(generate_host_entry "${env}")")
    done < <(get_environments)

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未找到任何环境定义${NC}"
        exit 0
    fi

    remove_kindler_entries
    add_kindler_entries "${entries[@]}"

    echo -e "${GREEN}✓ 已同步 ${#entries[@]} 个环境到 /etc/hosts${NC}"
    echo "已添加的域名:"
    printf '  %s\n' "${entries[@]}"
}

# 添加单个环境
add_environment() {
    local env="$1"

    echo -e "${YELLOW}添加环境 '${env}' 到 /etc/hosts...${NC}"

    load_config
    backup_hosts

    # 检查环境是否存在于 CSV
    if ! get_environments | grep -qx "${env}"; then
        echo -e "${RED}错误: 环境 '${env}' 未在 environments.csv 中定义${NC}" >&2
        exit 1
    fi

    local entry="$(generate_host_entry "${env}")"

    # 检查是否已存在 Kindler 标记
    if grep -q "${HOSTS_MARKER_START}" "${HOSTS_FILE}"; then
        # 在结束标记前插入新条目
        sed -i.tmp "/${HOSTS_MARKER_END}/i ${entry}" "${HOSTS_FILE}"
        rm -f "${HOSTS_FILE}.tmp"
    else
        # 创建新的标记块
        add_kindler_entries "${entry}"
    fi

    echo -e "${GREEN}✓ 已添加: ${entry}${NC}"
}

# 移除单个环境
remove_environment() {
    local env="$1"

    echo -e "${YELLOW}从 /etc/hosts 移除环境 '${env}'...${NC}"

    load_config
    backup_hosts

    local domain="${env}.${BASE_DOMAIN}"

    # 移除匹配的行
    sed -i.tmp "/${domain}/d" "${HOSTS_FILE}"
    rm -f "${HOSTS_FILE}.tmp"

    echo -e "${GREEN}✓ 已移除 ${domain} 的条目${NC}"
}

# 清理所有 Kindler 条目
clean_all() {
    echo -e "${YELLOW}清理所有 Kindler 条目...${NC}"

    backup_hosts
    remove_kindler_entries

    echo -e "${GREEN}✓ 已清理所有 Kindler 条目${NC}"
}

# 显示帮助信息
show_help() {
    cat <<EOF
用法: sudo $0 [选项]

选项:
  --sync              同步所有环境到 /etc/hosts
  --add <env>         添加单个环境
  --remove <env>      移除单个环境
  --clean             清理所有 Kindler 条目
  -h, --help          显示此帮助信息

示例:
  sudo $0 --sync
  sudo $0 --add dev
  sudo $0 --remove dev
  sudo $0 --clean

说明:
  - 此脚本需要 root 权限（sudo）
  - 每次操作前会自动备份 /etc/hosts
  - 备份文件位于: /etc/hosts.kindler.YYYYMMDD_HHMMSS.bak
  - 如果使用 sslip.io/nip.io，无需运行此脚本

配置文件:
  - config/clusters.env      # BASE_DOMAIN, HAPROXY_HOST
  - config/environments.csv  # 环境列表
EOF
}

# 主函数
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    case "$1" in
        --sync)
            check_root
            sync_all
            ;;
        --add)
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}错误: --add 需要指定环境名称${NC}" >&2
                echo "用法: sudo $0 --add <env>" >&2
                exit 1
            fi
            check_root
            add_environment "$2"
            ;;
        --remove)
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}错误: --remove 需要指定环境名称${NC}" >&2
                echo "用法: sudo $0 --remove <env>" >&2
                exit 1
            fi
            check_root
            remove_environment "$2"
            ;;
        --clean)
            check_root
            clean_all
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}错误: 未知选项 '$1'${NC}" >&2
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
