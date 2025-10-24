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

	echo "[BOOTSTRAP] Create shared Docker network for devops cluster"
	SHARED_NETWORK="k3d-shared"
	# devops 集群使用共享网络（172.18.0.0/16），业务集群使用独立子网
	# HAProxy 和 Portainer 也连接到此网络以访问 devops 集群
	if ! docker network inspect "$SHARED_NETWORK" >/dev/null 2>&1; then
		echo "[NETWORK] Creating shared network: $SHARED_NETWORK (172.18.0.0/16)"
		docker network create "$SHARED_NETWORK" \
			--subnet 172.18.0.0/16 \
			--gateway 172.18.0.1 \
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

	echo "[BOOTSTRAP] Ensure HAProxy config has correct permissions"
	chmod 644 "$ROOT_DIR/compose/infrastructure/haproxy.cfg" 2>/dev/null || true

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

	echo "[BOOTSTRAP] Waiting for Portainer to be ready (timeout: 120s)..."
	# Portainer 端口未暴露到宿主机，使用 docker exec 检查容器内健康状态
	if ! timeout 120 bash -c 'while ! docker exec portainer-ce wget -q -O- http://localhost:9000/api/system/status >/dev/null 2>&1; do sleep 2; done'; then
		echo "[ERROR] Portainer failed to start within 120s"
		docker logs portainer-ce --tail 20
		exit 1
	fi
	echo "[BOOTSTRAP] Portainer is ready"

	echo "[BOOTSTRAP] Adding local Docker endpoint to Portainer..."
	"$ROOT_DIR/scripts/portainer_add_local.sh"

	# 创建 devops 集群（幂等性检查）
	if ! kubectl config get-contexts k3d-devops >/dev/null 2>&1; then
		echo "[BOOTSTRAP] Creating devops cluster..."
		PROVIDER=k3d "$ROOT_DIR/scripts/cluster.sh" create devops || {
			echo "[ERROR] Failed to create devops cluster"
			exit 1
		}
		
		# 导入 k3d 基础设施镜像（pause, coredns）到集群
		echo "[BOOTSTRAP] Importing k3d infrastructure images to devops cluster..."
		k3d_infra_images=(
			"rancher/mirrored-pause:3.6"
			"rancher/mirrored-coredns-coredns:1.12.0"
		)
		for img in "${k3d_infra_images[@]}"; do
			if docker images -q "$img" >/dev/null 2>&1; then
				echo "  Importing $img..."
				k3d image import "$img" -c devops 2>/dev/null || echo "  [WARN] Failed to import $img"
			fi
		done
		
		echo "[BOOTSTRAP] Installing ArgoCD in devops cluster..."
		"$ROOT_DIR/scripts/setup_devops.sh" || {
			echo "[ERROR] Failed to install ArgoCD"
			exit 1
		}
	else
		echo "[BOOTSTRAP] devops cluster already exists"
		# 检查 ArgoCD 是否已安装
		if ! kubectl --context k3d-devops get ns argocd >/dev/null 2>&1; then
			echo "[BOOTSTRAP] Installing ArgoCD in existing devops cluster..."
			"$ROOT_DIR/scripts/setup_devops.sh" || {
				echo "[ERROR] Failed to install ArgoCD"
				exit 1
			}
		else
			echo "[BOOTSTRAP] ArgoCD already installed"
		fi
	fi

	echo "[BOOTSTRAP] Validate external Git configuration"
	"$ROOT_DIR/scripts/setup_git.sh"

	echo "[BOOTSTRAP] Initialize external Git devops branch"
	"$ROOT_DIR/scripts/init_git_devops.sh"

	echo "[BOOTSTRAP] Setup devops cluster storage support"
	"$ROOT_DIR/scripts/setup_devops_storage.sh"

	echo "[BOOTSTRAP] Register external Git repository to ArgoCD"
	"$ROOT_DIR/scripts/register_git_to_argocd.sh" devops
	
	echo "[BOOTSTRAP] Deploy PostgreSQL via ArgoCD"
	"$ROOT_DIR/scripts/deploy_postgresql_gitops.sh"
	
	echo "[BOOTSTRAP] Setup PostgreSQL NodePort Service"
	"$ROOT_DIR/scripts/setup_postgresql_nodeport.sh"
	
	echo "[BOOTSTRAP] Setup HAProxy PostgreSQL TCP proxy"
	"$ROOT_DIR/scripts/setup_haproxy_postgres.sh"
	
	echo "[BOOTSTRAP] Initialize database tables"
	"$ROOT_DIR/scripts/init_database.sh"
	
	echo "[BOOTSTRAP] Record devops cluster to database"
	# devops 集群已创建，现在数据库已就绪，记录到数据库
	. "$ROOT_DIR/scripts/lib_db.sh"
	if db_is_available; then
		devops_server_ip=$(docker inspect k3d-devops-server-0 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}' || echo "")
		if [ -z "$devops_server_ip" ]; then
			echo "[WARN] Could not detect devops server IP"
			devops_server_ip="10.101.0.4"
		fi
		echo "[DEVOPS] Server IP: $devops_server_ip"
		
		max_retries=3
		for attempt in $(seq 1 $max_retries); do
			if db_insert_cluster "devops" "k3d" "" "30800" "19000" "10800" "10843" "$devops_server_ip" 2>/tmp/db_devops_bootstrap.log; then
				echo "[DEVOPS] ✓ devops cluster recorded to database"
				break
			else
				if [ $attempt -eq $max_retries ]; then
					echo "[ERROR] Failed to record devops cluster after $max_retries attempts"
					echo "[ERROR] Error: $(cat /tmp/db_devops_bootstrap.log 2>/dev/null || echo 'no log')"
					echo "[ERROR] This is critical - WebUI will not show devops cluster"
					exit 1
				else
					echo "[WARN] Database insert failed (attempt $attempt/$max_retries), retrying in 3s..."
					sleep 3
				fi
			fi
		done
	else
		echo "[ERROR] Database not available after init_database.sh - this should not happen!"
		exit 1
	fi
	
	echo "[BOOTSTRAP] Sync Git branches from database"
	if [ -f "$ROOT_DIR/scripts/sync_git_from_db.sh" ]; then
		"$ROOT_DIR/scripts/sync_git_from_db.sh" 2>&1 | sed 's/^/  /' || echo "  [WARN] Git sync failed (can be done manually later)"
	fi
	
	echo "[BOOTSTRAP] Fix HAProxy routes for business clusters"
	if [ -f "$ROOT_DIR/scripts/fix_haproxy_routes.sh" ]; then
		"$ROOT_DIR/scripts/fix_haproxy_routes.sh" 2>&1 | sed 's/^/  /'
	fi

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
