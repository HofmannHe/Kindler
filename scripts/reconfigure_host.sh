#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
  cat >&2 <<USAGE
Usage: $0 --host-ip <ip> [--sslip | --base-domain <domain>] [--add-alias] [--dry-run]

Options:
  --host-ip <ip>       New host IP for HAProxy entry (e.g., 192.168.88.10)
  --sslip              Use <ip>.sslip.io as BASE_DOMAIN (zero-DNS)
  --base-domain <dom>  Use a custom BASE_DOMAIN (e.g., local)
  --add-alias          Attempt to add <ip> as a temporary alias on the default NIC
  --dry-run            Print planned changes and checks without executing

This updates config/clusters.env (HAPROXY_HOST/BASE_DOMAIN), refreshes HAProxy routes,
re-applies devops Ingress for ArgoCD, regenerates ApplicationSet, and runs curl checks.
USAGE
}

HOST_IP=""; BASE_DOMAIN=""; USE_SSLIP=0; ADD_ALIAS=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host-ip) HOST_IP="$2"; shift 2 ;;
    --sslip) USE_SSLIP=1; shift ;;
    --base-domain) BASE_DOMAIN="$2"; shift 2 ;;
    --add-alias) ADD_ALIAS=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$HOST_IP" ] || { echo "--host-ip is required" >&2; usage; exit 2; }
if [ $USE_SSLIP -eq 1 ] && [ -n "$BASE_DOMAIN" ]; then
  echo "--sslip and --base-domain are mutually exclusive" >&2; exit 2
fi
if [ $USE_SSLIP -eq 1 ]; then BASE_DOMAIN="${HOST_IP}.sslip.io"; fi
[ -n "$BASE_DOMAIN" ] || BASE_DOMAIN="${HOST_IP}.sslip.io"

log(){ printf "[%s] %s\n" "$1" "$2"; }
run(){ if [ $DRY -eq 1 ]; then echo "+ $*"; else eval "$*"; fi }

# 1) Optionally add IP alias to default interface (requires privileges)
if [ $ADD_ALIAS -eq 1 ]; then
  def_if="$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
  if [ -z "$def_if" ]; then def_if="$(ip route | awk '/default/ {print $5; exit}')"; fi
  if [ -n "$def_if" ]; then
    log INFO "Adding alias $HOST_IP/32 to $def_if"
    run "ip addr add ${HOST_IP}/32 dev ${def_if} || true"
  else
    log WARN "Cannot detect default interface; skip alias"
  fi
fi

# 2) Update config/clusters.env
CFG="$ROOT_DIR/config/clusters.env"
[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 3; }
log INFO "Updating HAPROXY_HOST=$HOST_IP BASE_DOMAIN=$BASE_DOMAIN in $CFG"
if [ $DRY -eq 1 ]; then
  sed -n '1,200p' "$CFG" | sed -e "s/^HAPROXY_HOST=.*/HAPROXY_HOST=$HOST_IP/" -e "s/^BASE_DOMAIN=.*/BASE_DOMAIN=$BASE_DOMAIN/" >/dev/null
else
  tmp=$(mktemp)
  awk -v ip="$HOST_IP" -v dom="$BASE_DOMAIN" '
    BEGIN{h=0;b=0}
    /^HAPROXY_HOST=/ {print "HAPROXY_HOST=" ip; h=1; next}
    /^BASE_DOMAIN=/ {print "BASE_DOMAIN=" dom; b=1; next}
    {print}
    END{
      if(h==0) print "HAPROXY_HOST=" ip;
      if(b==0) print "BASE_DOMAIN=" dom;
    }
  ' "$CFG" >"$tmp" && mv "$tmp" "$CFG"
fi

# 3) Refresh HAProxy routes / devops ingress / ApplicationSet
log INFO "Syncing HAProxy routes"
run "$ROOT_DIR/scripts/haproxy_sync.sh --prune"
log INFO "Re-applying devops ArgoCD ingress"
run "$ROOT_DIR/scripts/setup_devops.sh"
log INFO "Regenerating ApplicationSet"
run "$ROOT_DIR/scripts/sync_applicationset.sh"

# 4) Curl checks
. "$ROOT_DIR/scripts/lib.sh" || true
load_env || true
HTTP_PORT="${HAPROXY_HTTP_PORT:-80}"
base_url="http://${HOST_IP}"
[ "$HTTP_PORT" != "80" ] && base_url="http://${HOST_IP}:${HTTP_PORT}"

echo "" >>"$ROOT_DIR/docs/TEST_REPORT.md"
echo "## Reconfigure Host Run @ $(date -Is)" >>"$ROOT_DIR/docs/TEST_REPORT.md"
echo "- host: $HOST_IP, base_domain: $BASE_DOMAIN" >>"$ROOT_DIR/docs/TEST_REPORT.md"

check_host(){
  local host="$1" desc="$2" code
  if [ $DRY -eq 1 ]; then
    echo "[DRY] curl -I -H 'Host: $host' $base_url"
    echo "- $desc ($host): DRY" >>"$ROOT_DIR/docs/TEST_REPORT.md"
    return 0
  fi
  code=$(curl -sS -o /dev/null -w '%{http_code}' -I -H "Host: $host" "$base_url" || echo "000")
  echo "$desc ($host): $code"
  echo "- $desc ($host): $code" >>"$ROOT_DIR/docs/TEST_REPORT.md"
}

check_host "portainer.devops.${BASE_DOMAIN}" "portainer-http"
check_host "argocd.devops.${BASE_DOMAIN}" "argocd"

# business whoami from CSV
if [ -f "$ROOT_DIR/config/environments.csv" ]; then
  while IFS=, read -r env provider node_port pf_port reg_portainer haproxy_route http_port https_port; do
    case "$env" in ''|\#*) continue;; esac
    [ "$env" = "devops" ] && continue
    host_env="$(env_label "$env")"
    check_host "whoami.${host_env}.${BASE_DOMAIN}" "whoami-${env}"
  done < "$ROOT_DIR/config/environments.csv"
fi

log INFO "Done"

