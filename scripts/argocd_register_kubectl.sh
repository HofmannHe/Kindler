#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

register_cluster_kubectl() {
  local cluster_name="$1"
  local provider="${2:-k3d}"

  . "$ROOT_DIR/scripts/lib.sh"
  local eff; eff="$(effective_name "$cluster_name")"
  local context_name
  if [[ "$provider" == "k3d" ]]; then
    context_name="k3d-${eff}"
  else
    context_name="kind-${eff}"
  fi

  echo "[INFO] Registering cluster ${context_name} to ArgoCD via kubectl..."

  # 检查集群是否存在
  if ! kubectl config get-contexts "${context_name}" &>/dev/null; then
    echo "[ERROR] Cluster context ${context_name} not found"
    return 1
  fi

  # 获取集群 API server 地址（使用容器内网 IP 以支持跨集群连接）
  local api_server
  if [[ "$provider" == "k3d" ]]; then
    # k3d: 使用容器内网 IP（共享网络 k3d-shared）
    local container_name="k3d-${eff}-server-0"
    local container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name" 2>/dev/null | head -1)
    if [[ -z "$container_ip" ]]; then
      echo "[ERROR] Failed to get container IP for $container_name"
      return 1
    fi
    api_server="https://${container_ip}:6443"
    echo "[INFO] Using container IP for API server: $api_server"
  else
    # kind: 使用 kubeconfig 中的地址，若为 127.0.0.1 或 0.0.0.0 则改为 host.k3d.internal
    api_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${context_name}')].cluster.server}")
    api_server=${api_server/127.0.0.1/host.k3d.internal}
    api_server=${api_server/0.0.0.0/host.k3d.internal}
  fi

  # 获取 CA 证书
  local ca_data=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${context_name}')].cluster.certificate-authority-data}")

  # 创建 ServiceAccount 用于 ArgoCD 访问
  echo "[INFO] Creating argocd-manager ServiceAccount in ${context_name}..."
  kubectl --context "${context_name}" create namespace argocd 2>/dev/null || true

  cat <<EOF | kubectl --context "${context_name}" apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager-role
rules:
- apiGroups:
  - '*'
  resources:
  - '*'
  verbs:
  - '*'
- nonResourceURLs:
  - '*'
  verbs:
  - '*'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager-role
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: kube-system
EOF

  # 等待 ServiceAccount token 创建
  echo "[INFO] Waiting for ServiceAccount token..."
  sleep 2

  # 创建 token secret (Kubernetes 1.24+)
  cat <<EOF | kubectl --context "${context_name}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

  sleep 2

  # 获取 token
  local token=$(kubectl --context "${context_name}" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)

  if [[ -z "$token" ]]; then
    echo "[ERROR] Failed to get ServiceAccount token"
    return 1
  fi

  # 创建 ArgoCD cluster secret
  echo "[INFO] Creating ArgoCD cluster secret..."
  insecure=false
  if [[ "$provider" != "k3d" ]]; then insecure=true; fi

  if [[ "$provider" == "k3d" ]]; then
  # Secret name uses effective cluster name to avoid collisions
  cat <<EOF | kubectl --context k3d-devops apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${eff}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${eff}
  server: ${api_server}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": ${insecure},
        "caData": "${ca_data}"
      }
    }
EOF
  else
    cat <<EOF | kubectl --context k3d-devops apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${eff}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${eff}
  server: ${api_server}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF
  fi

  echo "[SUCCESS] Cluster ${cluster_name} registered to ArgoCD"
  echo "[INFO] Verify with: kubectl --context k3d-devops get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster"
}

unregister_cluster_kubectl() {
  local cluster_name="$1"
  local provider="${2:-k3d}"

  . "$ROOT_DIR/scripts/lib.sh"
  local eff; eff="$(effective_name "$cluster_name")"
  local context_name
  if [[ "$provider" == "k3d" ]]; then
    context_name="k3d-${eff}"
  else
    context_name="kind-${eff}"
  fi

  echo "[INFO] Unregistering cluster ${cluster_name} from ArgoCD..."

  # 删除 ArgoCD cluster secret（兼容老名称和命名空间后缀名称）
  kubectl --context k3d-devops delete secret "cluster-${cluster_name}" -n argocd --ignore-not-found=true || true
  kubectl --context k3d-devops delete secret "cluster-${eff}" -n argocd --ignore-not-found=true || true

  # 删除集群中的 ServiceAccount 和 RBAC
  if kubectl config get-contexts "${context_name}" &>/dev/null; then
    kubectl --context "${context_name}" delete clusterrolebinding argocd-manager-role-binding --ignore-not-found=true
    kubectl --context "${context_name}" delete clusterrole argocd-manager-role --ignore-not-found=true
    kubectl --context "${context_name}" delete serviceaccount argocd-manager -n kube-system --ignore-not-found=true
    kubectl --context "${context_name}" delete secret argocd-manager-token -n kube-system --ignore-not-found=true
  fi

  echo "[SUCCESS] Cluster ${cluster_name} unregistered from ArgoCD"
}

# Main
action="${1:-register}"
cluster_name="${2:-}"
provider="${3:-k3d}"

if [[ -z "$cluster_name" ]]; then
  echo "Usage: $0 <register|unregister> <cluster_name> [provider]"
  echo "Example: $0 register dev-k3d k3d"
  echo "Example: $0 unregister dev-k3d k3d"
  exit 1
fi

case "$action" in
  register)
    register_cluster_kubectl "$cluster_name" "$provider"
    ;;
  unregister)
    unregister_cluster_kubectl "$cluster_name" "$provider"
    ;;
  *)
    echo "[ERROR] Unknown action: $action"
    echo "Usage: $0 <register|unregister> <cluster_name> [provider]"
    exit 1
    ;;
esac
