#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# Load configuration
if [ -f "$ROOT_DIR/config/clusters.env" ]; then
	. "$ROOT_DIR/config/clusters.env"
fi
: "${HAPROXY_HOST:=192.168.51.30}"

# Load secrets
if [ -f "$ROOT_DIR/config/secrets.env" ]; then
	. "$ROOT_DIR/config/secrets.env"
fi
: "${ARGOCD_ADMIN_PASSWORD:=admin123}"
: "${ARGOCD_VERSION:=v3.1.8}"
: "${ARGOCD_NODEPORT:=30800}"

# 验证 devops 集群已存在（应由 bootstrap.sh 创建）
if ! kubectl --context k3d-devops get nodes >/dev/null 2>&1; then
	echo "[ERROR] devops cluster not found or not accessible"
	echo "[ERROR] Please run bootstrap.sh to create the devops cluster first"
	exit 1
fi
echo "[DEVOP] devops cluster is accessible"

# 预热 ArgoCD 镜像到 k3d 集群（避免拉取超时）
echo "[DEVOP] Preloading ArgoCD images to cluster..."
. "$ROOT_DIR/scripts/lib.sh"
argocd_image="quay.io/argoproj/argocd:${ARGOCD_VERSION}"
if prefetch_image "$argocd_image"; then
	echo "[DEVOP] Importing ArgoCD image to devops cluster..."
	k3d image import "$argocd_image" -c devops 2>/dev/null || true
else
	echo "[WARN] Failed to prefetch ArgoCD image, deployment may be slow"
fi

# 检查 ArgoCD 是否已安装（幂等性）
if kubectl --context k3d-devops get ns argocd >/dev/null 2>&1 && \
   kubectl --context k3d-devops get deploy -n argocd argocd-server >/dev/null 2>&1; then
	echo "[DEVOP] ArgoCD already installed, skipping installation"
	# 验证 ArgoCD server 是否运行
	if kubectl --context k3d-devops get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q '^Running$'; then
		echo "[DEVOP] ArgoCD server is running"
	else
		echo "[DEVOP] ArgoCD server not running, will reconfigure"
	fi
else
	# 安装 ArgoCD (使用官方 manifest)
	echo "[DEVOP] Installing ArgoCD using official manifest..."
	kubectl --context k3d-devops create namespace argocd || true

	# 尝试使用本地缓存或下载官方 manifest
	ARGOCD_MANIFEST="$ROOT_DIR/manifests/argocd/install-${ARGOCD_VERSION}.yaml"
	ARGOCD_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

	if [ ! -f "$ARGOCD_MANIFEST" ]; then
		echo "[DEVOP] Downloading ArgoCD ${ARGOCD_VERSION} manifest..."
		mkdir -p "$(dirname "$ARGOCD_MANIFEST")"
		if curl -sSL -m 30 "$ARGOCD_URL" -o "$ARGOCD_MANIFEST" 2>/dev/null; then
			echo "[DEVOP] Downloaded successfully"
		else
			echo "[ERROR] Failed to download ArgoCD manifest from GitHub"
			echo "[ERROR] Please manually download:"
			echo "[ERROR]   curl -sSL $ARGOCD_URL -o $ARGOCD_MANIFEST"
			echo "[ERROR] Or fix network connectivity to raw.githubusercontent.com"
			exit 1
		fi
	else
		echo "[DEVOP] Using cached ArgoCD manifest: $ARGOCD_MANIFEST"
	fi

	kubectl --context k3d-devops apply -n argocd -f "$ARGOCD_MANIFEST"
fi

# 等待 ArgoCD server（增加超时时间到 10 分钟）
echo "[DEVOP] Waiting for ArgoCD server to be ready (max 600s = 10min)..."
. "$ROOT_DIR/scripts/lib.sh"
ensure_pod_running_with_preload "k3d-devops" argocd 'app.kubernetes.io/name=argocd-server' k3d devops "quay.io/argoproj/argocd:${ARGOCD_VERSION}" 600 || {
	echo "[ERROR] ArgoCD server failed to start within timeout"
	kubectl --context k3d-devops get pods -n argocd -l app.kubernetes.io/name=argocd-server
	kubectl --context k3d-devops describe pods -n argocd -l app.kubernetes.io/name=argocd-server | tail -30
	exit 1
}

# 配置 ArgoCD
echo "[DEVOP] Configuring ArgoCD..."

# 1. 修改 service 为 NodePort
kubectl --context k3d-devops patch svc argocd-server -n argocd -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":80,\"nodePort\":${ARGOCD_NODEPORT}}]}}"

# 2. 启用 insecure 模式（HTTP 访问）
kubectl --context k3d-devops patch cm argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'

# 3. 应用自定义健康检查配置（修复 Ingress 永远 Progressing 的问题）
echo "[DEVOP] Applying custom health check for Ingress resources..."
kubectl --context k3d-devops apply -f "$ROOT_DIR/manifests/argocd/argocd-cm-custom-health.yaml"

# 3. 设置自定义 admin 密码
echo "[DEVOP] Setting custom admin password..."
password_bcrypt=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ARGOCD_ADMIN_PASSWORD'.encode('utf-8'), bcrypt.gensalt(rounds=10)).decode('utf-8'))")
kubectl --context k3d-devops -n argocd patch secret argocd-secret -p "{\"stringData\": {\"admin.password\": \"$password_bcrypt\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"
kubectl --context k3d-devops -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true

# 4. 重启 argocd-server 应用配置
# Note: devops 集群禁用了 Traefik，直接通过 NodePort 暴露服务
kubectl --context k3d-devops rollout restart deploy/argocd-server -n argocd
# 等待 argocd-server 重启就绪（增加超时时间）
. "$ROOT_DIR/scripts/lib.sh"
ensure_pod_running_with_preload "k3d-devops" argocd 'app.kubernetes.io/name=argocd-server' k3d devops "quay.io/argoproj/argocd:${ARGOCD_VERSION}" 300 || {
	echo "[WARN] ArgoCD server restart may not be complete, but continuing..."
}

# 连接 HAProxy 到 devops可访问的网络
# 说明：devops 集群默认使用 k3d-shared 网络；历史脚本尝试连接 k3d-devops 会在网络不存在时导致 HAProxy 重启失败
echo "[DEVOP] Ensuring HAProxy is attached to k3d-shared (if present)"
if docker network inspect k3d-shared >/dev/null 2>&1; then
  if docker inspect haproxy-gw 2>/dev/null | jq -e '.[0].NetworkSettings.Networks["k3d-shared"]' >/dev/null 2>&1; then
    echo "[INFO] HAProxy already connected to k3d-shared"
  else
    docker network connect k3d-shared haproxy-gw 2>/dev/null || echo "[WARN] failed to connect haproxy-gw to k3d-shared (continuing)"
  fi
else
  echo "[WARN] k3d-shared network not found; skipping"
fi
# 历史上连接 k3d-devops 的行为在网络不存在时会失败，这里仅在网络存在且未连接时尝试；不再强制重启
if docker network inspect k3d-devops >/dev/null 2>&1; then
  if docker inspect haproxy-gw 2>/dev/null | jq -e '.[0].NetworkSettings.Networks["k3d-devops"]' >/dev/null 2>&1; then
    :
  else
    docker network connect k3d-devops haproxy-gw 2>/dev/null || echo "[INFO] HAProxy connect to k3d-devops skipped/failed"
  fi
fi

# 添加 HAProxy 路由 (使用 NodePort 30800)
echo "[DEVOP] Skipping HAProxy dynamic route for devops (management cluster has static routes)"
# devops 是管理集群，使用静态路由（git, portainer, argocd, haproxy）
# 不添加动态通配路由，避免干扰特定服务路由

# Ensure argocd host routing points to current devops NodePort (be_argocd)
# NOTE:
# - A k3d server container通常连接多个网络（如 k3d-shared 和专用子网），
#   直接使用 '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 会把多个IP无分隔拼接，
#   导致类似 '10.101.0.4172.18.0.6' 的非法地址，引发 HAProxy 验证失败。
# - 优先选择 k3d-shared 网络的 IP；若不存在，再回退到第一个 IP（以空格分隔后取第一个）。
DEVOPS_NODE_IP=""
if DEVOPS_NODE_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "k3d-shared"}}{{.IPAddress}}{{end}}' k3d-devops-server-0 2>/dev/null); then
  :
fi
if [ -z "$DEVOPS_NODE_IP" ]; then
  # 回退：以空格分隔所有IP，仅取第一个
  DEVOPS_NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' k3d-devops-server-0 2>/dev/null | awk '{print $1}' || true)
fi
if [ -n "$DEVOPS_NODE_IP" ]; then
  CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
  # Rewrite the entire be_argocd block to a single server line to avoid duplicates
  awk -v ip="$DEVOPS_NODE_IP" -v port="$ARGOCD_NODEPORT" '
    BEGIN{inblk=0}
    {
      if ($0 ~ /^[[:space:]]*backend[[:space:]]+be_argocd[[:space:]]*$/) {
        print $0;                   # backend line
        print "  server s1 " ip ":" port;  # single server line
        inblk=1;                    # skip old content of this backend
        next
      }
      if (inblk) {
        if ($0 ~ /^[[:space:]]*backend[[:space:]]+/) { inblk=0; print $0 } else { next }
      } else {
        print $0
      }
    }
  ' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  docker restart haproxy-gw >/dev/null 2>&1 || true
  echo "[DEVOP] be_argocd -> ${DEVOPS_NODE_IP}:${ARGOCD_NODEPORT}"
fi

echo ""
echo "✅ [DEVOP] Setup complete!"
echo ""
echo "ArgoCD Access:"
if [ "${HAPROXY_HTTP_PORT:-80}" = "80" ]; then
	echo "  URL: http://${HAPROXY_HOST}/"
else
	echo "  URL: http://${HAPROXY_HOST}:${HAPROXY_HTTP_PORT}/"
fi
if [ "${HAPROXY_HTTP_PORT:-80}" = "80" ]; then
	echo "  Domain: http://argocd.devops.${BASE_DOMAIN}"
else
	echo "  Domain: http://argocd.devops.${BASE_DOMAIN}:${HAPROXY_HTTP_PORT}"
fi
echo "  Username: admin"
echo "  Password: $ARGOCD_ADMIN_PASSWORD"
echo ""

# Note: devops 集群的数据库记录由 bootstrap.sh 在 init_database.sh 之后执行
# 不在这里记录，因为 setup_devops.sh 执行时数据库还未部署
