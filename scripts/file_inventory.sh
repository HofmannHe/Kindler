#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Validate that Markdown docs in repo root, docs/, and selected top-level subdirectories are registered in the FILE_INVENTORY tree (root FILE_INVENTORY.md + docs/FILE_INVENTORY.md) or live under history/archive.
# Usage: scripts/file_inventory.sh [--check]
# Category: inventory
# Status: stable
# See also: FILE_INVENTORY.md, docs/FILE_INVENTORY.md

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_INVENTORY_FILE="$ROOT_DIR/FILE_INVENTORY.md"
DOCS_INVENTORY_FILE="$ROOT_DIR/docs/FILE_INVENTORY.md"

usage() {
  echo "Usage: $(basename "$0") [--check]" >&2
}

die() {
  echo "[file-inventory] ERROR: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$ROOT_INVENTORY_FILE" ]]; then
  die "inventory file not found: FILE_INVENTORY.md"
fi

if [[ ! -f "$DOCS_INVENTORY_FILE" ]]; then
  die "inventory file not found: docs/FILE_INVENTORY.md"
fi

# 收集根目录与 docs/ 清单中声明的 Path（去掉反引号与表头）
collect_paths_from_inventory() {
  local file="$1"
  sed -n '/^| *Path /,$p' "$file" \
    | grep '^|' \
    | tail -n +3 \
    | sed -E 's/^\| *`?([^`]+)`?.*/\1/' \
    | sed 's/^ *//;s/ *$//' \
    | grep -v '^Path' || true
}

mapfile -t declared_paths < <(
  collect_paths_from_inventory "$ROOT_INVENTORY_FILE"
  collect_paths_from_inventory "$DOCS_INVENTORY_FILE"
)

declare -A declared
for p in "${declared_paths[@]}"; do
  [[ -n "$p" ]] || continue
  declared["$p"]=1
done

# 扫描根目录和受管子目录下的 Markdown 文件
# 约束：本脚本仅负责“仓库根目录 + 一级子目录（docs/、scripts/、webui/）” 两个层级；
# 更深层级（例如 examples/kindler-config/、webui/backend/）由对应子目录下的 FILE_INVENTORY/README 单独管理。
mapfile -t repo_md < <(
  cd "$ROOT_DIR" && find . \
    -maxdepth 2 \
    -type f \
    -name '*.md' \
    ! -path './.git/*' \
    ! -path './openspec/*' \
    ! -path './worktrees/*' \
    ! -path './docs/history/*' \
    ! -path './docs/archive/*' \
    | sed 's|^./||'
)

unknown=()
for f in "${repo_md[@]}"; do
  # 只关注根目录 (无子目录前缀) 以及 docs/、scripts/、webui/ 下的文档
  case "$f" in
    docs/*|scripts/*.md|webui/*.md)
      ;;
    *.md)
      case "$f" in
        */*)  # 其它子目录文档交由对应子目录清单管理
          continue
          ;;
      esac
      ;;
    *)
      continue
      ;;
  esac

  # 历史/归档目录在上面的 find 中已排除

  if [[ -n "${declared[$f]:-}" ]]; then
    continue
  fi

  # 清单自身不需要登记
  if [[ "$f" == 'FILE_INVENTORY.md' || "$f" == 'docs/FILE_INVENTORY.md' ]]; then
    continue
  fi

  unknown+=("$f")
done

if [[ ${#unknown[@]} -eq 0 ]]; then
  echo "[file-inventory] OK: 根目录与 docs/ 下的 Markdown 文档均在 FILE_INVENTORY.md/docs/FILE_INVENTORY.md 清单中登记，或位于历史/归档目录。"
  exit 0
fi

echo "[file-inventory] 以下 Markdown 文档未在 FILE_INVENTORY 清单树中登记，且不在 docs/history 或 docs/archive 目录：" >&2
for f in "${unknown[@]}"; do
  echo "  - $f" >&2
done

die "未登记文档需要被分类为：核心文档（补充根/子目录清单）/ 历史案例（迁移到 docs/history）/ 废弃（删除）"
