#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Validate that Markdown docs under tools/ are registered in tools/FILE_INVENTORY.md.
# Usage: tools/file_inventory.sh [--check]
# Category: inventory
# Status: stable
# See also: tools/FILE_INVENTORY.md

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_REL="tools"
INVENTORY_FILE="$ROOT_DIR/$DIR_REL/FILE_INVENTORY.md"

usage() {
  echo "Usage: $(basename "$0") [--check]" >&2
}

die() {
  echo "[file-inventory:$DIR_REL] ERROR: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$INVENTORY_FILE" ]]; then
  die "inventory file not found: $DIR_REL/FILE_INVENTORY.md"
fi

# 收集清单中声明的 Path（去掉反引号与表头）
mapfile -t declared_paths < <(
  sed -n '/^## tools\/ 目录结构/I,$p' "$INVENTORY_FILE" \
    | grep '^|' \
    | sed -E 's/^\| *`?([^`]+)`?.*/\1/' \
    | sed 's/^ *//;s/ *$//' \
    | grep -v '^Path' || true
)

declare -A declared
for p in "${declared_paths[@]}"; do
  [[ -n "$p" ]] || continue
  declared["$p"]=1
done

# 扫描 tools/ 及其一级子目录下的 Markdown 文件
mapfile -t repo_md < <(
  cd "$ROOT_DIR/$DIR_REL" && find . \
    -maxdepth 2 \
    -type f \
    -name '*.md' \
    ! -path './.git/*' \
    ! -path './worktrees/*' \
    | sed "s|^./|$DIR_REL/|"
)

unknown=()
for f in "${repo_md[@]}"; do
  case "$f" in
    ${DIR_REL}/*) ;;
    *) continue ;;
  esac

  # 清单文件自身不需要登记
  if [[ "$f" == "$DIR_REL/FILE_INVENTORY.md" ]]; then
    continue
  fi

  if [[ -n "${declared[$f]:-}" ]]; then
    continue
  fi

  unknown+=("$f")
done

if [[ ${#unknown[@]} -eq 0 ]]; then
  echo "[file-inventory:$DIR_REL] OK: 所有 Markdown 文档均在 $DIR_REL/FILE_INVENTORY.md 清单中登记。"
  exit 0
fi

echo "[file-inventory:$DIR_REL] 以下 Markdown 文档未在 $DIR_REL/FILE_INVENTORY.md 中登记：" >&2
for f in "${unknown[@]}"; do
  echo "  - $f" >&2
done

die "未登记文档需要被分类为：核心工具文档（补充清单）/ 历史案例（迁移到 docs/history）/ 废弃（删除）"

