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

echo "[DEVOP] Creating devops k3d cluster..."
"$ROOT_DIR"/scripts/create_env.sh -n devops --no-register-argocd

# 等待集群就绪
echo "[DEVOP] Waiting for cluster to be ready..."
kubectl --context k3d-devops wait --for=condition=ready node --all --timeout=60s

# 安装 ArgoCD (使用官方 manifest)
echo "[DEVOP] Installing ArgoCD using official manifest..."
kubectl --context k3d-devops create namespace argocd || true

# 尝试使用本地缓存或下载官方 manifest
ARGOCD_MANIFEST="$ROOT_DIR/manifests/argocd/install-${ARGOCD_VERSION}.yaml"
ARGOCD_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

if [ ! -f "$ARGOCD_MANIFEST" ]; then
	echo "[DEVOP] Downloading ArgoCD ${ARGOCD_VERSION} manifest..."
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

# 等待 ArgoCD server，就绪失败则预热镜像后重试
echo "[DEVOP] Waiting for ArgoCD server to be ready (with preload retry)..."
. "$ROOT_DIR/scripts/lib.sh"
ensure_pod_running_with_preload "k3d-devops" argocd 'app.kubernetes.io/name=argocd-server' k3d devops "quay.io/argoproj/argocd:${ARGOCD_VERSION}" 600 || true

# 配置 ArgoCD
echo "[DEVOP] Configuring ArgoCD..."

# 1. 修改 service 为 NodePort
kubectl --context k3d-devops patch svc argocd-server -n argocd -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":80,\"nodePort\":${ARGOCD_NODEPORT}}]}}"

# 2. 启用 insecure 模式（HTTP 访问）
kubectl --context k3d-devops patch cm argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'

# 3. 设置自定义 admin 密码
echo "[DEVOP] Setting custom admin password..."
password_bcrypt=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ARGOCD_ADMIN_PASSWORD'.encode('utf-8'), bcrypt.gensalt(rounds=10)).decode('utf-8'))")
kubectl --context k3d-devops -n argocd patch secret argocd-secret -p "{\"stringData\": {\"admin.password\": \"$password_bcrypt\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"
kubectl --context k3d-devops -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true

# 4. 配置 ArgoCD Ingress 以匹配域名规则
ARGOCD_HOST="argocd.devops.${BASE_DOMAIN}"
kubectl --context k3d-devops apply -n argocd -f - <<INGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-http
spec:
  ingressClassName: traefik
  rules:
    - host: ${ARGOCD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
INGRESS

# 5. 重启 argocd-server 应用配置
kubectl --context k3d-devops rollout restart deploy/argocd-server -n argocd
# 使用通用预热重试再次等待 argocd-server 就绪
. "$ROOT_DIR/scripts/lib.sh"
ensure_pod_running_with_preload "k3d-devops" argocd 'app.kubernetes.io/name=argocd-server' k3d devops "quay.io/argoproj/argocd:${ARGOCD_VERSION}" 600 || true

# 连接 HAProxy 到 devops 网络
echo "[DEVOP] Connecting HAProxy to devops network..."
docker network connect k3d-devops haproxy-gw 2>/dev/null || echo "[INFO] HAProxy already connected"
docker restart haproxy-gw

# 添加 HAProxy 路由 (使用 NodePort 30800)
echo "[DEVOP] Adding HAProxy route..."
"$ROOT_DIR"/scripts/haproxy_route.sh add devops --node-port 30800

# Ensure argocd host routing points to current devops NodePort (be_argocd)
DEVOPS_NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' k3d-devops-server-0 2>/dev/null || true)
if [ -n "$DEVOPS_NODE_IP" ]; then
  CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
  awk -v ip="$DEVOPS_NODE_IP" -v port="$ARGOCD_NODEPORT" '
    BEGIN{ins=0}
    {print}
    /^backend be_argocd/ {getline; gsub(/.*/, "  server s1 " ip ":" port); print; ins=1}
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
