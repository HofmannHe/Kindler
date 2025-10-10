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

# Preload a container image into a cluster runtime to avoid ImagePullBackOff
# Usage: preload_image_to_cluster <provider> <cluster-name> <image>
preload_image_to_cluster() {
  local provider="$1" name="$2" image="$3"
  if [ -z "$provider" ] || [ -z "$name" ] || [ -z "$image" ]; then
    log WARN "preload_image_to_cluster: missing args"
    return 1
  fi
  log INFO "Preloading image '$image' into ${provider}/${name}..."
  if has_image "$image"; then
    : # ok
  else
    prefetch_image "$image" || true
  fi
  if [ "$provider" = "k3d" ]; then
    if command -v k3d >/dev/null 2>&1; then
      k3d image import "$image" -c "$name" >/dev/null 2>&1 || true
    fi
  else
    # kind: copy into control-plane and import via containerd ctr
    local node_ctn="${name}-control-plane"
    if ! has_image "$image"; then prefetch_image "$image" || true; fi
    local tmp_tar
    tmp_tar=$(mktemp /tmp/preload.XXXXXX.tar)
    if docker save -o "$tmp_tar" "$image" 2>/dev/null; then
      if docker cp "$tmp_tar" "$node_ctn":/preload.tar 2>/dev/null && docker exec "$node_ctn" ctr -n k8s.io images import /preload.tar >/dev/null 2>&1; then
        log INFO "Image '$image' imported into $node_ctn"
      else
        log WARN "Failed to import image into $node_ctn"
      fi
    fi
    rm -f "$tmp_tar" 2>/dev/null || true
  fi
}

# Check if local docker has image (any tag digest available)
has_image() { docker image inspect "$1" >/dev/null 2>&1; }

# Prefetch an image with retries, prefer local registry/cached tags if present
# Usage: prefetch_image <image>
prefetch_image() {
  local image="$1"
  [ -n "$image" ] || return 1
  # If already present, skip
  if has_image "$image"; then
    log INFO "image cached: $image"
    return 0
  fi
  # Try local registry mirror variant if available
  local reg_img="localhost:5000/${image}"
  if has_image "$reg_img"; then
    docker tag "$reg_img" "$image" >/dev/null 2>&1 || true
    log INFO "tagged from local registry: $reg_img -> $image"
    return 0
  fi
  # Pull with retries
  for i in 1 2 3; do
    if docker pull "$image" >/dev/null 2>&1; then
      log INFO "pulled: $image"
      return 0
    fi
    sleep $((i*2))
  done
  log WARN "prefetch failed: $image"
  return 1
}

# Wait until pods match selector are Running; on failure, preload image + retry with backoff
# Usage: ensure_pod_running_with_preload <ctx> <namespace> <label-selector> <provider> <cluster-name> <image> <timeout-seconds>
ensure_pod_running_with_preload() {
  local ctx="$1" ns="$2" sel="$3" provider="$4" name="$5" image="$6" timeout="${7:-180}"
  local attempt=0 max_attempts=3 base_wait=4 status waited step

  while [ $attempt -lt $max_attempts ]; do
    # quick wait loop before deciding to preload
    waited=0; step=$base_wait
    while [ $waited -lt "$timeout" ]; do
      status=$(kubectl --context "$ctx" get pods -n "$ns" -l "$sel" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
      [ "$status" = "Running" ] && return 0
      if [ $((waited % 10)) -eq 0 ]; then
        log INFO "waiting pods '$sel' in $ns (elapsed ${waited}s/${timeout}s, attempt $((attempt+1)))"
      fi
      sleep $step; waited=$((waited+step))
    done

    # not running within timeout: attempt preload + delete to restart
    log WARN "Pods '$sel' in $ns not Running; attempt $((attempt+1))/$max_attempts — preloading '$image'"
    preload_image_to_cluster "$provider" "$name" "$image"
    kubectl --context "$ctx" delete pod -n "$ns" -l "$sel" --force --grace-period=0 >/dev/null 2>&1 || true

    # exponential backoff for next cycle
    attempt=$((attempt+1))
    base_wait=$((base_wait*2))
  done

  # final check one last time
  status=$(kubectl --context "$ctx" get pods -n "$ns" -l "$sel" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  if [ "$status" = "Running" ]; then
    return 0
  fi
  log WARN "Pods with selector '$sel' in $ns not Running after retries"
  return 1
}
