#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"

usage(){ echo "Usage: $0 install <context> [--nodeport <port>]" >&2; exit 1; }
cmd="${1:-}"; ctx="${2:-}"; shift || true; shift || true || true
nodeport=30080
while [ $# -gt 0 ]; do
  case "$1" in
    --nodeport) nodeport="${2:-30080}"; shift 2;;
    *) break;;
  esac
done

case "$cmd" in
  install)
    [ -n "${ctx:-}" ] || usage
    
    echo "[TRAEFIK] Installing Traefik Ingress Controller to context: $ctx (NodePort: $nodeport)"
    
    # 检查是否已安装（幂等性）
    if kubectl --context "$ctx" get namespace traefik >/dev/null 2>&1 && \
       kubectl --context "$ctx" get deployment traefik -n traefik >/dev/null 2>&1; then
      echo "[TRAEFIK] Already installed, checking NodePort..."
      current_np=$(kubectl --context "$ctx" -n traefik get svc traefik -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
      if [ "$current_np" = "$nodeport" ]; then
        echo "[TRAEFIK] NodePort matches ($nodeport), skipping reinstall"
        exit 0
      else
        echo "[TRAEFIK] NodePort mismatch (current: $current_np, expected: $nodeport), updating..."
      fi
    fi
    
    # 预加载镜像到集群（避免 ImagePullBackOff）
    echo "[TRAEFIK] Preloading traefik:v2.10 image to cluster..."
    prefetch_image "traefik:v2.10" || true
    
    # 根据集群类型预加载镜像到集群内部
    cluster_name=$(echo "$ctx" | sed 's/^k3d-//;s/^kind-//')
    provider="kind"
    if echo "$ctx" | grep -q "^k3d-"; then
      provider="k3d"
    fi
    
    preload_image_to_cluster "$provider" "$cluster_name" "traefik:v2.10" || {
      log WARN "Failed to preload image to cluster, deployment may be slow"
    }
    
    # 根据集群类型选择配置
    # k3d: NodePort only (serverlb 转发到 NodePort，不用 hostPort 避免多集群冲突)
    # kind: NodePort only (HAProxy 直接访问容器 IP + NodePort)
    host_port_config=""
    if [ "$provider" = "k3d" ]; then
      echo "[TRAEFIK] Using NodePort $nodeport for k3d cluster (no hostPort to avoid conflicts)"
    else
      echo "[TRAEFIK] Using NodePort $nodeport for kind cluster"
    fi
    
    # 部署 Traefik（根据集群类型使用不同的 Service 配置）
    echo "[TRAEFIK] Deploying Traefik manifests..."
    cat <<EOF | kubectl --context "$ctx" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik
  namespace: traefik
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik
rules:
- apiGroups: [""]
  resources: ["services", "endpoints", "secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources: ["ingresses", "ingressclasses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources: ["ingresses/status"]
  verbs: ["update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik
subjects:
- kind: ServiceAccount
  name: traefik
  namespace: traefik
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik
  labels:
    app: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik
      containers:
      - name: traefik
        image: traefik:v2.10
        imagePullPolicy: IfNotPresent
        args:
        - --api.insecure=true
        - --providers.kubernetesingress
        - --entrypoints.web.address=:80
        - --log.level=INFO
        ports:
        - name: web
          containerPort: 80
          $host_port_config
        - name: admin
          containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: traefik
  labels:
    app: traefik
spec:
  type: NodePort
  selector:
    app: traefik
  ports:
  - name: web
    port: 80
    targetPort: 80
    nodePort: ${nodeport}
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: traefik.io/ingress-controller
EOF

    echo "[TRAEFIK] Waiting for Traefik deployment to be ready (max 300s)..."
    kubectl --context "$ctx" wait --for=condition=available --timeout=300s deployment/traefik -n traefik || {
      echo "[WARN] Traefik deployment not ready within 300s, checking status..."
      kubectl --context "$ctx" get pods -n traefik
      kubectl --context "$ctx" describe pods -n traefik | tail -30
      
      # 尝试重启失败的 pod
      echo "[TRAEFIK] Attempting to restart pods..."
      kubectl --context "$ctx" delete pods -n traefik -l app=traefik --force --grace-period=0 2>/dev/null || true
      
      # 再等待一次
      echo "[TRAEFIK] Waiting again after restart..."
      kubectl --context "$ctx" wait --for=condition=available --timeout=180s deployment/traefik -n traefik || {
        echo "[ERROR] Traefik still not ready after retry"
        return 1
      }
    }
    
    echo "[TRAEFIK] Installation complete"
    ;;
  *) usage ;;
esac
