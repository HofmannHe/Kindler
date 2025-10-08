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
		export GITEA_VERSION="${GITEA_VERSION:-1.22-rootless}"
	fi
	: "${HAPROXY_HOST:=192.168.51.30}"
	: "${HAPROXY_HTTP_PORT:=80}"
	: "${HAPROXY_HTTPS_PORT:=443}"
	: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"

	echo "[BOOTSTRAP] Create shared Docker network for k3d clusters"
	SHARED_NETWORK="k3d-shared"
	if ! docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1; then
		echo "[NETWORK] Creating shared network: $SHARED_NETWORK (10.100.0.0/16)"
		docker network create "$SHARED_NETWORK" \
			--subnet 10.100.0.0/16 \
			--gateway 10.100.0.1 \
			--opt com.docker.network.bridge.name=br-k3d-shared
		echo "[SUCCESS] Shared network created"
	else
		echo "[NETWORK] Shared network already exists"
	fi

	echo "[BOOTSTRAP] Ensure portainer_secrets volume exists"
	if [ -f "$ROOT_DIR/config/secrets.env" ]; then . "$ROOT_DIR/config/secrets.env"; fi
	: "${PORTAINER_ADMIN_PASSWORD:=admin123}"
	docker volume inspect portainer_secrets >/dev/null 2>&1 || docker volume create portainer_secrets >/dev/null
	docker run --rm -v portainer_secrets:/run/secrets alpine:3.20 \
		sh -lc "umask 077; printf '%s' '$PORTAINER_ADMIN_PASSWORD' > /run/secrets/portainer_admin"

	echo "[BOOTSTRAP] Start infrastructure (Portainer + HAProxy + Gitea)"
	docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d

	echo "[BOOTSTRAP] Waiting for Portainer to be ready..."
	: "${PORTAINER_HTTP_PORT:=9000}"
	PORTAINER_IP=$(docker inspect portainer-ce --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
	for i in {1..30}; do
		if curl -s http://${PORTAINER_IP}:${PORTAINER_HTTP_PORT}/api/system/status >/dev/null 2>&1; then
			echo "[BOOTSTRAP] Portainer is ready"
			break
		fi
		[ $i -eq 30 ] && {
			echo "[ERROR] Portainer failed to start"
			exit 1
		}
		sleep 2
	done

	echo "[BOOTSTRAP] Adding local Docker endpoint to Portainer..."
	"$ROOT_DIR/scripts/portainer_add_local.sh"

	echo "[BOOTSTRAP] Setup devops management cluster with ArgoCD"
	"$ROOT_DIR/scripts/setup_devops.sh"

	echo "[BOOTSTRAP] Initialize Gitea and repositories"
	"$ROOT_DIR/scripts/setup_git.sh"

	echo "[BOOTSTRAP] Register Gitea repository to ArgoCD"
	"$ROOT_DIR/scripts/register_git_to_argocd.sh" devops

	echo "[READY]"
	portainer_url="https://portainer.devops.${BASE_DOMAIN}"
	if [ "${HAPROXY_HTTPS_PORT}" != "443" ]; then
		portainer_url="${portainer_url}:${HAPROXY_HTTPS_PORT}"
	fi
	haproxy_url="http://haproxy.devops.${BASE_DOMAIN}"
	if [ "${HAPROXY_HTTP_PORT}" != "80" ]; then
		haproxy_url="${haproxy_url}:${HAPROXY_HTTP_PORT}"
	fi
	argocd_url="http://argocd.devops.${BASE_DOMAIN}"
	if [ "${HAPROXY_HTTP_PORT}" != "80" ]; then
		argocd_url="${argocd_url}:${HAPROXY_HTTP_PORT}"
	fi
	gitea_url="http://git.devops.${BASE_DOMAIN}"
	if [ "${HAPROXY_HTTP_PORT}" != "80" ]; then
		gitea_url="${gitea_url}:${HAPROXY_HTTP_PORT}"
	fi
	echo "- Portainer: ${portainer_url} (admin/$PORTAINER_ADMIN_PASSWORD)"
	echo "- HAProxy:   ${haproxy_url}/stat"
	echo "- ArgoCD:    ${argocd_url}"
	echo "- Gitea:     ${gitea_url} (gitea/gitea123456)"
}

main "$@"
