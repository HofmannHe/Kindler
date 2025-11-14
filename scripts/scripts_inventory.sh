#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Generate Markdown/JSON inventory from script metadata and verify docs/scripts_inventory.md is current.
# Usage: scripts/scripts_inventory.sh [--markdown|--json] [--output <file>] [--check]
# Category: inventory
# Status: stable
# See also: scripts/README.md, docs/scripts_inventory.md

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
INVENTORY_MD="$ROOT_DIR/docs/scripts_inventory.md"
MODE="markdown"
OUTPUT=""
CHECK=0

usage() {
  cat >&2 << 'USAGE'
Usage: scripts/scripts_inventory.sh [options]
  --markdown        Output Markdown (default)
  --json            Output JSON
  --output <file>   Write output to file instead of stdout
  --check           Regenerate Markdown and ensure docs/scripts_inventory.md matches
  -h, --help        Show this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --markdown) MODE="markdown" ;;
    --json) MODE="json" ;;
    --output)
      OUTPUT="${2:-}"
      [ -n "$OUTPUT" ] || {
        echo "[ERROR] --output requires a path" >&2
        exit 2
      }
      shift
      ;;
    --check) CHECK=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

# data structures
declare -a SCRIPT_NAMES=()
declare -A DESC_MAP=()
declare -A USAGE_MAP=()
declare -A CATEGORY_MAP=()
declare -A STATUS_MAP=()
declare -A SEE_MAP=()
declare -A CATEGORY_COUNTS=()
declare -A STATUS_COUNTS=()

md_escape() {
  local str="$1"
  str=${str//|/\|}
  str=${str//$'\n'/<br/>}
  printf '%s' "$str"
}

json_escape() {
  local str="$1"
  str=${str//\\/\\\\}
  str=${str//\"/\\\"}
  str=${str//$'\n'/\\n}
  printf '%s' "$str"
}

collect_scripts() {
  local path name
  mapfile -t script_paths < <(find "$ROOT_DIR/scripts" -maxdepth 1 -type f -name '*.sh' -print | sort)
  if [ ${#script_paths[@]} -eq 0 ]; then
    echo "[ERROR] No scripts found under scripts/" >&2
    exit 1
  fi
  for path in "${script_paths[@]}"; do
    name="$(basename "$path")"
    parse_metadata "$name" "$path"
  done
}

parse_metadata() {
  local name="$1" path="$2"
  local desc="" usage_line="" category="" status="" see=""
  while IFS= read -r line; do
    case "$line" in
      "# Description: "*) desc="${line#\# Description: }" ;;
      "# Usage: "*) usage_line="${line#\# Usage: }" ;;
      "# Category: "*) category="${line#\# Category: }" ;;
      "# Status: "*) status="${line#\# Status: }" ;;
      "# See also: "*) see="${line#\# See also: }" ;;
    esac
  done < <(sed -n '1,40p' "$path")

  if [ -z "$desc" ] || [ -z "$usage_line" ] || [ -z "$category" ] || [ -z "$status" ]; then
    echo "[ERROR] Missing metadata in $path (need Description/Usage/Category/Status)" >&2
    exit 1
  fi
  case "$status" in
    stable | experimental | deprecated) ;;
    *)
      echo "[ERROR] Invalid status '$status' in $path (expected stable|experimental|deprecated)" >&2
      exit 1
      ;;
  esac

  SCRIPT_NAMES+=("$name")
  DESC_MAP["$name"]="$desc"
  USAGE_MAP["$name"]="$usage_line"
  CATEGORY_MAP["$name"]="$category"
  STATUS_MAP["$name"]="$status"
  SEE_MAP["$name"]="$see"
  CATEGORY_COUNTS["$category"]=$((CATEGORY_COUNTS["$category"] + 1))
  STATUS_COUNTS["$status"]=$((STATUS_COUNTS["$status"] + 1))
}

sorted_categories() {
  for key in "${!CATEGORY_COUNTS[@]}"; do
    printf '%s\n' "$key"
  done | sort
}

scripts_in_category() {
  local target="$1" name
  for name in "${SCRIPT_NAMES[@]}"; do
    if [ "${CATEGORY_MAP[$name]}" = "$target" ]; then
      printf '%s\n' "$name"
    fi
  done | sort
}

generate_markdown() {
  local now
  now="${INVENTORY_TIMESTAMP:-}"
  printf -- '# Scripts Inventory\n\n'
  if [ -n "$now" ]; then
    printf -- '_Generated %s via scripts/scripts_inventory.sh_\n\n' "$now"
  else
    printf -- '_Generated via scripts/scripts_inventory.sh_\n\n'
  fi

  printf -- '## Summary\n'
  printf -- '- Total scripts: %d\n' "${#SCRIPT_NAMES[@]}"
  printf -- '- Status counts:\n'
  for status in $(printf '%s\n' "${!STATUS_COUNTS[@]}" | sort); do
    printf -- '  - %s: %d\n' "$status" "${STATUS_COUNTS[$status]}"
  done
  printf -- '- Category counts:\n'
  for cat in $(sorted_categories); do
    printf -- '  - %s: %d\n' "$cat" "${CATEGORY_COUNTS[$cat]}"
  done
  printf -- '\n'

  for cat in $(sorted_categories); do
    printf -- '### %s\n\n' "$cat"
    printf -- '| Script | Description | Usage | Status | See also |\n'
    printf -- '| --- | --- | --- | --- | --- |\n'
    while IFS= read -r script_name; do
      local desc usage_line status see
      desc=$(md_escape "${DESC_MAP[$script_name]}")
      usage_line=$(md_escape "${USAGE_MAP[$script_name]}")
      status="${STATUS_MAP[$script_name]}"
      see=${SEE_MAP[$script_name]:--}
      if [ -n "$see" ]; then
        see=$(md_escape "$see")
      else
        see='-'
      fi
      printf -- "| \`%s\` | %s | \`%s\` | %s | %s |\n" "scripts/$script_name" "$desc" "$usage_line" "$status" "$see"
    done < <(scripts_in_category "$cat")
    printf -- '\n'
  done
}

generate_json() {
  local first=1 name
  printf -- '{"generated_at":"%s","scripts":[' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  for name in $(printf '%s\n' "${SCRIPT_NAMES[@]}" | sort); do
    if [ $first -eq 0 ]; then
      printf -- ','
    fi
    first=0
    printf -- '{"name":"%s","path":"scripts/%s","description":"%s","usage":"%s","category":"%s","status":"%s"' \
      "$(json_escape "$name")" "$(json_escape "$name")" "$(json_escape "${DESC_MAP[$name]}")" \
      "$(json_escape "${USAGE_MAP[$name]}")" "$(json_escape "${CATEGORY_MAP[$name]}")" "$(json_escape "${STATUS_MAP[$name]}")"
    if [ -n "${SEE_MAP[$name]}" ]; then
      printf -- ',"see_also":"%s"' "$(json_escape "${SEE_MAP[$name]}")"
    fi
    printf -- '}'
  done
  printf -- ']}\n'
}

write_output() {
  local tmp
  tmp=$(mktemp)
  if [ "$MODE" = "json" ]; then
    generate_json > "$tmp"
  else
    generate_markdown > "$tmp"
  fi

  if [ -n "$OUTPUT" ]; then
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$tmp" "$OUTPUT"
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

run_check() {
  local tmp
  tmp=$(mktemp)
  generate_markdown > "$tmp"
  if [ ! -f "$INVENTORY_MD" ] || ! cmp -s "$tmp" "$INVENTORY_MD"; then
    echo "[ERROR] docs/scripts_inventory.md is stale. Run scripts/scripts_inventory.sh --markdown --output docs/scripts_inventory.md" >&2
    if [ -f "$INVENTORY_MD" ]; then
      diff -u "$INVENTORY_MD" "$tmp" >&2 || true
    fi
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
  echo "[CHECK] docs/scripts_inventory.md is up-to-date."
}

collect_scripts

if [ "$CHECK" -eq 1 ]; then
  run_check
  exit 0
fi

write_output
