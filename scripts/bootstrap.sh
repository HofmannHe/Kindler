#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

main() {
    if [ "${DRY_RUN:-}" = "1" ]; then
        echo "[DRY-RUN][BOOTSTRAP] 将执行如下步骤:"
        echo "  1) 创建共享网络 k3d-shared"
        echo "  2) 准备 portainer_secrets 卷并写入管理员密码文件"
        echo "  3) 预热关键镜像 (并行+重试)"
        echo "  4) docker compose 启动 Portainer + HAProxy"
        echo "  5) 等待 Portainer 就绪并添加本地 Docker endpoint"
        echo "  6) 创建 devops 集群并安装/配置 ArgoCD (NodePort)"
        echo "  7) 配置外部 Git 并注册到 ArgoCD"
        echo "  8) 打印访问入口"
        exit 0
    fi
	# Load configuration
	if [ -f "$ROOT_DIR/config/clusters.env" ]; then
		. "$ROOT_DIR/config/clusters.env"
		# Export versions and network config for docker-compose
		export PORTAINER_VERSION="${PORTAINER_VERSION:-2.33.2-alpine}"
		export HAPROXY_VERSION="${HAPROXY_VERSION:-3.2.6-alpine3.22}"
		export HAPROXY_FIXED_IP="${HAPROXY_FIXED_IP:-10.100.255.100}"
	fi
	: "${HAPROXY_HOST:=192.168.51.30}"
	: "${HAPROXY_HTTP_PORT:=80}"
	: "${HAPROXY_HTTPS_PORT:=443}"
	: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"

	# 注意：不再创建全局 k3d-shared 网络
	# 每个 k3d 集群使用独立的子网（在 cluster.sh 中创建）
	# 这样可以避免子网重叠冲突，HAProxy 通过连接各集群网络来访问
	echo "[BOOTSTRAP] Skip creating k3d-shared network (using dedicated subnets per cluster)"

	echo "[BOOTSTRAP] Ensure portainer_secrets volume exists"
	if [ -f "$ROOT_DIR/config/secrets.env" ]; then . "$ROOT_DIR/config/secrets.env"; fi
	: "${PORTAINER_ADMIN_PASSWORD:=admin123}"
	docker volume inspect portainer_secrets >/dev/null 2>&1 || docker volume create portainer_secrets >/dev/null
	docker run --rm -v portainer_secrets:/run/secrets alpine:3.20 \
		sh -lc "umask 077; printf '%s' '$PORTAINER_ADMIN_PASSWORD' > /run/secrets/portainer_admin"

	echo "[BOOTSTRAP] Start infrastructure (Portainer + HAProxy)"
	docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d --remove-orphans

	# 预热关键镜像（并行+重试，跳过本地已有）
	echo "[BOOTSTRAP] Preheating core images..."
	: "${ARGOCD_VERSION:=v3.1.8}"
	imgs=(
	  "library/traefik:v2.10"
	  "traefik/whoami:v1.10.2"
	  "portainer/agent:latest"
	  "quay.io/argoproj/argocd:${ARGOCD_VERSION}"
	)
	for img in "${imgs[@]}"; do
	  (
	    . "$ROOT_DIR/scripts/lib.sh"
	    if has_image "$img"; then echo "  [=] cached: $img"; exit 0; fi
	    if prefetch_image "$img"; then echo "  [+] $img"; exit 0; fi
	    echo "  [!] failed prefetch: $img" >&2
	  ) &
	done
	wait || true

echo "[BOOTSTRAP] Waiting for Portainer to be ready..."
: "${PORTAINER_HTTP_PORT:=9000}"
# 使用 Portainer 在 management 网络中的固定 IP
PORTAINER_IP="${PORTAINER_FIXED_IP:-10.100.255.101}"
for i in {1..30}; do
	if curl -s http://${PORTAINER_IP}:${PORTAINER_HTTP_PORT}/api/system/status >/dev/null 2>&1; then
		echo "[BOOTSTRAP] Portainer is ready (IP: ${PORTAINER_IP}:${PORTAINER_HTTP_PORT})"
		break
	fi
	[ $i -eq 30 ] && {
		echo "[ERROR] Portainer failed to start"
		docker logs portainer-ce --tail 20
		exit 1
	}
	sleep 2
done

	echo "[BOOTSTRAP] Adding local Docker endpoint to Portainer..."
	"$ROOT_DIR/scripts/portainer_add_local.sh"

	# 检查 devops 集群是否已存在（幂等性）
	if k3d cluster list 2>/dev/null | grep -q '^devops\s'; then
		echo "[BOOTSTRAP] devops cluster already exists, skipping creation"
		# 检查 ArgoCD 是否已安装
		if kubectl --context k3d-devops get ns argocd >/dev/null 2>&1 && \
		   kubectl --context k3d-devops get deploy -n argocd argocd-server >/dev/null 2>&1; then
			echo "[BOOTSTRAP] ArgoCD already installed in devops cluster"
		else
			echo "[BOOTSTRAP] Installing ArgoCD in existing devops cluster"
			"$ROOT_DIR/scripts/setup_devops.sh"
		fi
	else
		echo "[BOOTSTRAP] Setup devops management cluster with ArgoCD"
		"$ROOT_DIR/scripts/setup_devops.sh"
	fi

	echo "[BOOTSTRAP] Validate external Git configuration"
	"$ROOT_DIR/scripts/setup_git.sh"

	echo "[BOOTSTRAP] Register external Git repository to ArgoCD"
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
	echo "- Portainer: ${portainer_url} (admin/$PORTAINER_ADMIN_PASSWORD)"
	echo "- HAProxy:   ${haproxy_url}/stat"
	echo "- ArgoCD:    ${argocd_url}"
}

main "$@"
