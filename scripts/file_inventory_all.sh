#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Validate that all Git-tracked files are registered in FILE_INVENTORY_ALL.md (global strict whitelist).
# Usage: scripts/file_inventory_all.sh [--check] [--prune]
# Category: inventory
# Status: stable
# See also: FILE_INVENTORY_ALL.md

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY_FILE="$ROOT_DIR/FILE_INVENTORY_ALL.md"

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/file_inventory_all.sh [--check] [--prune]

  --check   Validate that FILE_INVENTORY_ALL.md matches git ls-files (default)
  --prune   删除所有“已被 Git 跟踪但不在清单中的文件”（仅删除工作区文件，不自动提交）
USAGE
}

die() {
  echo "[file-inventory:all] ERROR: $*" >&2
  exit 1
}

MODE="check"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --prune) MODE="prune" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[file-inventory:all] Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

[[ -f "$INVENTORY_FILE" ]] || die "inventory file not found: FILE_INVENTORY_ALL.md"

# 收集清单中的 Path（去掉反引号与表头）
mapfile -t declared_paths < <(
  sed -n '/^| *Path /,$p' "$INVENTORY_FILE" \
    | grep '^|' \
    | tail -n +3 \
    | sed -E 's/^\| *`?([^`]+)`?.*/\1/' \
    | sed 's/^ *//;s/ *$//' || true
)

declare -A DECLARED
for p in "${declared_paths[@]}"; do
  [[ -n "$p" ]] || continue
  DECLARED["$p"]=1
done

# Git 跟踪的所有文件
mapfile -t tracked_files < <(cd "$ROOT_DIR" && git ls-files)

missing=()  # 被 Git 跟踪但未在清单中的文件
for f in "${tracked_files[@]}"; do
  if [[ -z "${DECLARED[$f]:-}" ]]; then
    missing+=("$f")
  fi
done

if [[ "$MODE" == "check" ]]; then
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "[file-inventory:all] OK: FILE_INVENTORY_ALL.md 与 git ls-files 一致。"
    exit 0
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[file-inventory:all] 以下文件已被 Git 跟踪，但未在 FILE_INVENTORY_ALL.md 中登记：" >&2
    for f in "${missing[@]}"; do
      echo "  - $f" >&2
    done
  fi

  die "请根据需要：删除多余文件、补充清单条目或更新 FILE_INVENTORY_ALL.md。"
fi

# MODE=prune：删除“被 Git 跟踪但不在清单中的文件”的工作区副本（不自动提交）
if [[ ${#missing[@]} -eq 0 ]]; then
  echo "[file-inventory:all] 没有需要清理的文件：所有 Git 跟踪文件均在清单中。"
  exit 0
fi

echo "[file-inventory:all] 将删除以下未在 FILE_INVENTORY_ALL.md 中登记的文件（仅工作区，不自动提交）：" >&2
for f in "${missing[@]}"; do
  echo "  - $f" >&2
done

for f in "${missing[@]}"; do
  rm -f "$ROOT_DIR/$f" || die "删除失败: $f"
done

echo "[file-inventory:all] 清理完成（请使用 git status 查看变化并按需提交）。"
