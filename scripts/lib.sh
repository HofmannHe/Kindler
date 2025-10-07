#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf "[%s] %s\n" "${1}" "${2:-}"; }
need_cmd() {
	if command -v "$1" >/dev/null 2>&1; then return 0; fi
	if [ "${DRY_RUN:-}" = "1" ]; then
		log WARN "missing command '$1' (DRY_RUN=1, proceed)"
		return 0
	fi
	log WARN "SKIP: missing command '$1'"
	return 1
}

load_env() {
	# shellcheck disable=SC1091
	if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi
}

env_label() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

ctx_name() {
	local env="$1"
	case "$env" in
	dev) echo "${CLUSTER_DEV:-dev}" ;;
	uat) echo "${CLUSTER_UAT:-uat}" ;;
	prod) echo "${CLUSTER_PROD:-prod}" ;;
	ops) echo "${CLUSTER_OPS:-ops}" ;;
	*) echo "$env" ;;
	esac
}

provider_for() {
	local env="$1"
	# check PROVIDER environment variable first
	if [ -n "${PROVIDER:-}" ]; then
		echo "$PROVIDER"
		return
	fi
	# prefer CSV if available
	local line provider
	line=$(csv_lookup "$env" || true)
	if [ -n "$line" ]; then
		IFS=, read -r _env provider _np _pf _rp _hr _hp _hs <<<"$line"
		IFS=$'
	'
		if [ -n "${provider:-}" ]; then
			echo "$provider"
			return
		fi
	fi
	case "$env" in
	dev) echo "${PROVIDER_DEV:-kind}" ;;
	uat) echo "${PROVIDER_UAT:-kind}" ;;
	prod) echo "${PROVIDER_PROD:-kind}" ;;
	ops) echo "${PROVIDER_OPS:-kind}" ;;
	*) echo kind ;;
	esac
}

ports_for() {
	local env="$1" line hp hs
	line=$(csv_lookup "$env" || true)
	if [ -n "$line" ]; then
		IFS=, read -r _env _prov _np _pf _rp _hr hp hs <<<"$line"
		IFS=$'
	'
		if [ -n "${hp:-}" ] && [ -n "${hs:-}" ]; then
			echo "$hp $hs"
			return
		fi
	fi
	case "$env" in
	dev) echo "${DEV_HTTP:-18090} ${DEV_HTTPS:-18443}" ;;
	uat) echo "${UAT_HTTP:-28080} ${UAT_HTTPS:-28443}" ;;
	prod) echo "${PROD_HTTP:-38080} ${PROD_HTTPS:-38443}" ;;
	ops) echo "${OPS_HTTP:-48080} ${OPS_HTTPS:-48443}" ;;
	*) echo " " ;;
	esac
}

# CSV lookup from config/environments.csv
csv_lookup() {
	local n="$1" csv="$ROOT_DIR/config/environments.csv"
	[ -f "$csv" ] || return 1
	# return comma-separated line for env n, ignoring comments/blank
	awk -F, -v n="$n" 'BEGIN{IGNORECASE=0} $0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print; exit}' "$csv" | tr -d ''
}
