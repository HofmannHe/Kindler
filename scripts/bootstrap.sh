#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

main() {
  # Load configuration
  if [ -f "$ROOT_DIR/config/clusters.env" ]; then
    . "$ROOT_DIR/config/clusters.env"
    # Export versions for docker-compose
    export PORTAINER_VERSION="${PORTAINER_VERSION:-2.33.2-alpine}"
    export HAPROXY_VERSION="${HAPROXY_VERSION:-3.2.6-alpine3.22}"
  fi
  : "${HAPROXY_HOST:=192.168.51.30}"
  : "${HAPROXY_UNIFIED_PORT:=23080}"
  : "${BASE_DOMAIN:=192.168.51.30.sslip.io}"

  echo "[BOOTSTRAP] Ensure portainer_secrets volume exists"
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then . "$ROOT_DIR/config/secrets.env"; fi
  : "${PORTAINER_ADMIN_PASSWORD:=admin123}"
  docker volume inspect portainer_secrets >/dev/null 2>&1 || docker volume create portainer_secrets >/dev/null
  docker run --rm -v portainer_secrets:/run/secrets alpine:3.20 \
    sh -lc "umask 077; printf '%s' '$PORTAINER_ADMIN_PASSWORD' > /run/secrets/portainer_admin"

  echo "[BOOTSTRAP] Start infrastructure (Portainer + HAProxy)"
  docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d

  echo "[BOOTSTRAP] Waiting for Portainer to be ready..."
  : "${PORTAINER_HTTP_PORT:=9000}"
  PORTAINER_IP=$(docker inspect portainer-ce --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
  for i in {1..30}; do
    if curl -s http://${PORTAINER_IP}:${PORTAINER_HTTP_PORT}/api/system/status >/dev/null 2>&1; then
      echo "[BOOTSTRAP] Portainer is ready"
      break
    fi
    [ $i -eq 30 ] && { echo "[ERROR] Portainer failed to start"; exit 1; }
    sleep 2
  done

  echo "[BOOTSTRAP] Adding local Docker endpoint to Portainer..."
  "$ROOT_DIR/scripts/portainer_add_local.sh"

  echo "[BOOTSTRAP] Setup devops management cluster with ArgoCD"
  "$ROOT_DIR/scripts/setup_devops.sh"

  echo "[READY]"
  echo "- Portainer: https://portainer.${BASE_DOMAIN}:23343 (admin/$PORTAINER_ADMIN_PASSWORD)"
  echo "- HAProxy:   http://${HAPROXY_HOST}:${HAPROXY_UNIFIED_PORT}"
  echo "- ArgoCD:    http://argocd.devops.${BASE_DOMAIN}:23800"
}

main "$@"
