#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Bring up the base devops stack (HAProxy, Portainer, WebUI, ArgoCD) and prepare shared networks/images.
# Usage: scripts/bootstrap.sh
# Category: lifecycle
# Status: stable
# See also: scripts/clean.sh, scripts/portainer.sh, tools/setup/setup_devops.sh

# shellcheck disable=SC2030,SC2031
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
readonly ROOT_DIR
# shellcheck source=scripts/lib/lib.sh
. "$ROOT_DIR/scripts/lib/lib.sh"

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
  if ! docker network inspect "$SHARED_NETWORK" > /dev/null 2>&1; then
    echo "[NETWORK] Creating shared network: $SHARED_NETWORK (172.18.0.0/16)"
    docker network create "$SHARED_NETWORK" \
      --subnet 172.18.0.0/16 \
      --gateway 172.18.0.1 \
      --opt com.docker.network.bridge.name=br-k3d-shared
    echo "[SUCCESS] Shared network created"
  else
    echo "[NETWORK] Shared network already exists"
  fi

  echo "[BOOTSTRAP] Ensure portainer_secrets volume exists (plaintext admin password)"
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then . "$ROOT_DIR/config/secrets.env"; fi
  : "${PORTAINER_ADMIN_PASSWORD:=admin123}"
  docker volume inspect portainer_secrets > /dev/null 2>&1 || docker volume create portainer_secrets > /dev/null
  # 写入明文密码（Portainer --admin-password-file 期望明文）
  docker run --rm -v portainer_secrets:/run/secrets alpine:3.20 \
    sh -lc "umask 077; printf '%s' \"${PORTAINER_ADMIN_PASSWORD}\" > /run/secrets/portainer_admin"

  echo "[BOOTSTRAP] Ensure HAProxy config has correct permissions"
  chmod 644 "$ROOT_DIR/compose/infrastructure/haproxy.cfg" 2> /dev/null || true

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
      if has_image "$img"; then
        echo "  [=] cached: $img"
        exit 0
      fi
      if prefetch_image "$img"; then
        echo "  [+] $img"
        exit 0
      fi
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
  if ! "$ROOT_DIR/scripts/portainer.sh" add-local; then
    echo "[WARN] Failed to add local Docker endpoint to Portainer (non-fatal)"
  fi

  # 创建 devops 集群（幂等性检查）
  if ! kubectl config get-contexts k3d-devops > /dev/null 2>&1; then
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
      if docker images -q "$img" > /dev/null 2>&1; then
        echo "  Importing $img..."
        k3d image import "$img" -c devops 2> /dev/null || echo "  [WARN] Failed to import $img"
      fi
    done

    echo "[BOOTSTRAP] Installing ArgoCD in devops cluster..."
    "$ROOT_DIR/tools/setup/setup_devops.sh" || {
      echo "[ERROR] Failed to install ArgoCD"
      exit 1
    }
  else
    echo "[BOOTSTRAP] devops cluster already exists"
    # 检查 ArgoCD 是否已安装
    if ! kubectl --context k3d-devops get ns argocd > /dev/null 2>&1; then
      echo "[BOOTSTRAP] Installing ArgoCD in existing devops cluster..."
      "$ROOT_DIR/tools/setup/setup_devops.sh" || {
        echo "[ERROR] Failed to install ArgoCD"
        exit 1
      }
    else
      echo "[BOOTSTRAP] ArgoCD already installed"
    fi
  fi

  echo "[BOOTSTRAP] Validate external Git configuration"
  "$ROOT_DIR/tools/setup/setup_git.sh"

  echo "[BOOTSTRAP] Initialize external Git devops branch"
  "$ROOT_DIR/tools/git/init_git_devops.sh"

  echo "[BOOTSTRAP] Setup devops cluster storage support"
  "$ROOT_DIR/tools/setup/setup_devops_storage.sh"

  echo "[BOOTSTRAP] Register external Git repository to ArgoCD"
  "$ROOT_DIR/tools/setup/register_git_to_argocd.sh" devops

  echo "[BOOTSTRAP] Sync Git branches from database"
  if [ -f "$ROOT_DIR/tools/git/sync_git_from_db.sh" ]; then
    "$ROOT_DIR/tools/git/sync_git_from_db.sh" 2>&1 | sed 's/^/  /' || echo "  [WARN] Git sync failed (can be done manually later)"
  fi

  echo "[BOOTSTRAP] Fix HAProxy routes for business clusters"
  if [ -f "$ROOT_DIR/tools/fix_haproxy_routes.sh" ]; then
    "$ROOT_DIR/tools/fix_haproxy_routes.sh" 2>&1 | sed 's/^/  /'
  fi

  echo "[BOOTSTRAP] Start WebUI services"
  if [ -d "$ROOT_DIR/webui" ]; then
    # 清理可能的僵尸容器
    docker rm -f kindler-webui-backend kindler-webui-frontend 2> /dev/null || true
    # 构建并启动 WebUI（在 infrastructure compose 中定义）
    cd "$ROOT_DIR/compose/infrastructure"
    echo "  Building WebUI images..."
    docker compose build kindler-webui-backend kindler-webui-frontend 2>&1 \
      | grep -E "Building|Built|Step|Successfully tagged" | tail -5 | sed 's/^/    /' || true
    # 兼容已经是 Up-to-date/Recreated 的情况，grep 匹配不到时不应失败
    docker compose up -d kindler-webui-backend kindler-webui-frontend 2>&1 \
      | grep -E "Creating|Created|Starting|Started|Recreated|Up-to-date" | sed 's/^/  /' || true
    # 等待服务就绪（通过容器健康检查）
    echo "  Waiting for WebUI to be ready..."
    for i in {1..60}; do
      if docker ps --filter "name=kindler-webui-backend" --filter "health=healthy" --format "{{.Names}}" | grep -q "kindler-webui-backend"; then
        echo "  ✓ WebUI backend is ready"
        break
      fi
      if [ "$i" -eq 60 ]; then
        echo "  ⚠ WebUI backend timeout (non-fatal)"
      else
        sleep 2
      fi
    done
    cd "$ROOT_DIR"

    # 从 CSV 导入数据到 SQLite（一次性初始化，幂等）
    echo "[BOOTSTRAP] Import CSV data to SQLite database"
    if [ -f "$ROOT_DIR/config/environments.csv" ]; then
      # 使用 WebUI 后端的 sync_from_csv 方法导入
      # 通过 Python 脚本调用 WebUI 的 db.py 的 sync_from_csv 方法
      if docker exec kindler-webui-backend python3 -c "
import sys
sys.path.insert(0, '/app')
from app.db import get_db
db = get_db()
db.sync_from_csv('/app/config/environments.csv')
print('CSV data imported successfully')
" 2> /dev/null; then
        echo "  ✓ CSV data imported to SQLite"

      else
        echo "  ⚠ CSV import failed (may already be imported)"
      fi
    else
      echo "  ⚠ CSV file not found: $ROOT_DIR/config/environments.csv"
    fi
  else
    echo "  ⚠ WebUI directory not found, skipping"
  fi

  # P2 修复：初始化 devops 集群在 SQLite 中的状态（仅管理用途，不触发业务部署）
  echo "[BOOTSTRAP] Initialize devops cluster state in SQLite (actual_state=running)"
  if docker ps --format '{{.Names}}' | grep -q '^kindler-webui-backend$'; then
    # 创建或更新 devops 行，避免覆盖其它字段（仅设置状态与时间戳）
    docker exec kindler-webui-backend sh -lc "sqlite3 /data/kindler-webui/kindler.db \"
			INSERT INTO clusters(name, provider, desired_state, actual_state, status, updated_at, last_reconciled_at)
			VALUES('devops','k3d','present','running','running', datetime('now'), datetime('now'))
			ON CONFLICT(name) DO UPDATE SET
			  provider='k3d',
			  desired_state='present',
			  actual_state='running',
			  status='running',
			  last_reconciled_at=datetime('now'),
			  updated_at=datetime('now');
			\"" > /dev/null 2>&1 || echo "  [WARN] Failed to initialize devops state"
  else
    echo "  [WARN] WebUI backend container not running, skip devops state init"
  fi

  # 注册 devops 集群到 Portainer（Edge Agent），便于在 Portainer 中可见管理集群
  # 允许通过环境变量关闭（默认开启）：REGISTER_DEVOPS_PORTAINER=0
  : "${REGISTER_DEVOPS_PORTAINER:=1}"
  if [ "$REGISTER_DEVOPS_PORTAINER" = "1" ]; then
    echo "[BOOTSTRAP] Register devops cluster to Portainer (Edge Agent)"
    "$ROOT_DIR/tools/setup/register_edge_agent.sh" devops k3d 2>&1 | sed 's/^/  /' || echo "  [WARN] Failed to register devops to Portainer"
  else
    echo "[BOOTSTRAP] Skipping Portainer registration for devops (REGISTER_DEVOPS_PORTAINER=0)"
  fi

  # 可选：将 devops 注册到 ArgoCD（默认关闭，仅当需要在 devops 部署业务时开启）
  if [ "${REGISTER_DEVOPS_ARGOCD:-0}" = "1" ]; then
    echo "[BOOTSTRAP] Register devops cluster to ArgoCD (optional)"
    "$ROOT_DIR/scripts/argocd_register.sh" register devops k3d 2>&1 | sed 's/^/  /' || echo "  [WARN] Failed to register devops to ArgoCD"
  fi

  echo "[BOOTSTRAP] Start Kindler Reconciler (declarative controller)"
  "$ROOT_DIR/tools/start_reconciler.sh" start 2>&1 | sed 's/^/  /' || echo "  [WARN] Failed to start reconciler (you can start it later)"

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
  webui_url="http://kindler.devops.${BASE_DOMAIN}"
  if [ "${HAPROXY_HTTP_PORT}" != "80" ]; then
    webui_url="${webui_url}:${HAPROXY_HTTP_PORT}"
  fi
  echo "- Portainer: ${portainer_url} (admin/$PORTAINER_ADMIN_PASSWORD)"
  echo "- HAProxy:   ${haproxy_url}/stat"
  echo "- ArgoCD:    ${argocd_url}"
  echo "- WebUI:     ${webui_url}"
  echo "- Reconciler: tail -f /tmp/kindler_reconciler.log (running)"
}

main "$@"
