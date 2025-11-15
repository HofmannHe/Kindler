#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Validate that every git-tracked file is covered by the FILE_INVENTORY tree (root + subdirectory FILE_INVENTORY.md).
# Usage: scripts/file_inventory_tree.sh [--check]
# Category: inventory
# Status: experimental
# See also: FILE_INVENTORY.md, docs/FILE_INVENTORY.md, FILE_INVENTORY_ALL.md

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/file_inventory_tree.sh [--check]

基于 FILE_INVENTORY 清单树（根目录 FILE_INVENTORY.md + 各子目录 FILE_INVENTORY.md），
验证所有由 git 跟踪的文件都能被某个清单条目（文件或上层目录）解释。
USAGE
}

die() {
  echo "[file-inventory:tree] ERROR: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  die "git 不可用，无法读取 git ls-files。"
fi

collect_paths_from_inventory() {
  local file="$1"
  # 从 Path 表头开始收集所有 Path 列，忽略表头本身
  sed -n '/^| *Path /,$p' "$file" \
    | grep '^|' \
    | tail -n +3 \
    | sed -E 's/^\| *`?([^`]+)`?.*/\1/' \
    | sed 's/^ *//;s/ *$//' \
    | grep -v '^Path' || true
}

declare -A INVENTORY_NODES

# 收集所有 FILE_INVENTORY.md 中声明的路径（文件或目录）
while IFS= read -r inv; do
  inv="${inv#./}"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    p="${p#./}"
    # 统一去掉末尾的斜杠，方便后续匹配 ancestor
    key="${p%/}"
    INVENTORY_NODES["$key"]=1
  done < <(collect_paths_from_inventory "$ROOT_DIR/$inv")
done < <(
  cd "$ROOT_DIR" && \
    find . \
      -type f \
      -name 'FILE_INVENTORY.md' \
      ! -path './.git/*' \
      ! -path './worktrees/*' \
      -print | sed 's|^./||'
)

if [[ ${#INVENTORY_NODES[@]} -eq 0 ]]; then
  die "未在仓库中找到任何 FILE_INVENTORY.md，无法构建清单树。"
fi

is_covered() {
  local path="$1"
  local current="$path"

  # 统一去掉前导 ./（与 git ls-files 保持一致）
  current="${current#./}"

  # 特例：根目录本身不需要清单条目
  [[ -z "$current" ]] && return 0

  while :; do
    local key="${current%/}"
    if [[ -n "${INVENTORY_NODES[$key]:-}" ]]; then
      return 0
    fi
    case "$current" in
      */*)
        current="${current%/*}"
        ;;
      *)
        break
        ;;
    esac
  done

  return 1
}

mapfile -t tracked_files < <(cd "$ROOT_DIR" && git ls-files)

missing=()
for f in "${tracked_files[@]}"; do
  # 当前规则：所有 git 跟踪文件都应当能在 FILE_INVENTORY 树中找到自身或上层目录的条目
  if ! is_covered "$f"; then
    missing+=("$f")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "[file-inventory:tree] OK: 所有 git 跟踪文件都能在 FILE_INVENTORY 清单树中找到对应条目（自身或上层目录）。"
  exit 0
fi

echo "[file-inventory:tree] 以下 git 跟踪文件未被任何 FILE_INVENTORY 条目覆盖（既无自身条目，也无上层目录条目）：" >&2
for f in "${missing[@]}"; do
  echo "  - $f" >&2
done

die "请为以上文件所在目录或文件本身在相应 FILE_INVENTORY.md 中补充 Purpose/Owner/Scope，或删除不再需要的文件。"

