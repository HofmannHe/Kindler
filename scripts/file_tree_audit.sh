#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Audit git-tracked files per directory and warn when a directory holds too many files.
# Usage: scripts/file_tree_audit.sh [--max-per-dir N]
# Category: inventory
# Status: experimental
# See also: FILE_INVENTORY_ALL.md

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_PER_DIR=15

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/file_tree_audit.sh [--max-per-dir N]

  --max-per-dir N   Recommended max files per directory (default: 15)

本脚本基于 `git ls-files` 统计每个目录下的文件数量，仅输出 WARNING 级别的结构审计结果，
不会修改仓库内容，也不会改变现有 clean/bootstrap/reconcile 流程的行为。
USAGE
}

die() {
  echo "[file-tree-audit] ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-per-dir)
      MAX_PER_DIR="${2:-}"
      [[ -n "$MAX_PER_DIR" ]] || die "--max-per-dir 需要一个数字参数"
      if ! [[ "$MAX_PER_DIR" =~ ^[0-9]+$ ]]; then
        die "--max-per-dir 必须是正整数"
      fi
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[file-tree-audit] Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

if ! command -v git >/dev/null 2>&1; then
  die "git 不可用，无法执行目录规模审计（需要 git ls-files）"
fi

cd "$ROOT_DIR"

declare -A DIR_COUNTS

while IFS= read -r path; do
  # 过滤不受管或特殊路径（通常不会出现在 git ls-files 中，但这里显式忽略以增加稳健性）
  case "$path" in
    .git/*|worktrees/*)
      continue
      ;;
  esac

  dir="${path%/*}"
  if [[ "$dir" == "$path" ]]; then
    dir="."  # 根目录文件
  fi
  current_count=${DIR_COUNTS["$dir"]:-0}
  DIR_COUNTS["$dir"]=$((current_count + 1))
done < <(git ls-files)

if [[ ${#DIR_COUNTS[@]} -eq 0 ]]; then
  echo "[file-tree-audit] 未找到 git 跟踪文件，跳过目录规模审计。"
  exit 0
fi

tmp_report="$(mktemp)"

for dir in "${!DIR_COUNTS[@]}"; do
  count="${DIR_COUNTS[$dir]}"
  printf '%s\t%d\n' "$dir" "$count" >> "$tmp_report"
done

echo "[file-tree-audit] 目录规模概览（仅统计 git ls-files）：" 
echo "  - 推荐上限: 每个目录约 ${MAX_PER_DIR} 个文件"
echo

over_limit=0

while IFS=$'\t' read -r dir count; do
  if (( count > MAX_PER_DIR )); then
    if (( over_limit == 0 )); then
      echo "[file-tree-audit] WARNING: 以下目录中的文件数量超过推荐上限（>${MAX_PER_DIR}）："
    fi
    over_limit=1
    printf '  - %s: %d files\n' "$dir" "$count"
  fi
done < <(sort -k2,2nr -k1,1 "$tmp_report")

rm -f "$tmp_report"

if (( over_limit == 0 )); then
  echo "[file-tree-audit] OK: 所有目录的文件数量均不超过推荐上限（>${MAX_PER_DIR}）。"
else
  echo
  echo "[file-tree-audit] 当前仅提供 WARNING，不会改变脚本或回归流程的退出码；"
  echo "                  后续可在目录清理完成后考虑引入严格模式。"
fi

exit 0
