#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Description: Register or unregister a cluster with ArgoCD via kubectl (serviceaccount token).
# Usage: scripts/argocd_register.sh <register|unregister> <cluster_name> [provider]
# Category: registration
# Status: stable
# See also: scripts/create_env.sh, scripts/delete_env.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"

# 从 Portainer Edge Agent Secret 读取凭证
get_portainer_credentials() {
  local cluster_name="$1"
  local provider="$2"
  local context_name
  if [[ "$provider" == "k3d" ]]; then
    context_name="k3d-${cluster_name}"
  else
    context_name="kind-${cluster_name}"
  fi

  local edge_id="" edge_key=""
  if kubectl --context "${context_name}" get secret portainer-edge-creds -n portainer-edge &> /dev/null; then
    edge_id=$(kubectl --context "${context_name}" get secret portainer-edge-creds -n portainer-edge -o jsonpath='{.data.edge-id}' 2> /dev/null | base64 -d || echo "")
    edge_key=$(kubectl --context "${context_name}" get secret portainer-edge-creds -n portainer-edge -o jsonpath='{.data.edge-key}' 2> /dev/null | base64 -d || echo "")
  fi
  echo "$edge_id|$edge_key"
}

register_cluster_once() {
  local cluster_name="$1"
  local provider="${2:-k3d}"

  local context_name
  if [[ "$provider" == "k3d" ]]; then
    context_name="k3d-${cluster_name}"
  else
    context_name="kind-${cluster_name}"
  fi

  echo "[INFO] Registering cluster ${context_name} to ArgoCD via kubectl..."

  # 检查集群是否存在
  if ! kubectl config get-contexts "${context_name}" &> /dev/null; then
    echo "[ERROR] Cluster context ${context_name} not found"
    return 1
  fi

  # 读取 Portainer 凭证（如果没有则使用空字符串）
  local credentials
  credentials=$(get_portainer_credentials "$cluster_name" "$provider")
  local edge_id
  edge_id=$(echo "$credentials" | cut -d'|' -f1)
  local edge_key
  edge_key=$(echo "$credentials" | cut -d'|' -f2)

  # 确保 annotations 始终存在（即使为空）
  if [[ -z "$edge_id" ]]; then edge_id=""; fi
  if [[ -z "$edge_key" ]]; then edge_key=""; fi

  # 获取集群 API server 地址（使用容器内网 IP 以支持跨集群连接）
  local api_server
  if [[ "$provider" == "k3d" ]]; then
    # k3d: 使用 host.k3d.internal:<serverlb_port>，保证 devops Pod 可访问
    local lb_name="k3d-${cluster_name}-serverlb"
    local host_port
    host_port=$(docker port "$lb_name" 6443/tcp 2> /dev/null | awk -F: '{print $NF}' | tail -1 || true)
    if [[ -z "$host_port" ]]; then
      echo "[ERROR] Failed to get serverlb host port for $lb_name"
      return 1
    fi
    api_server="https://host.k3d.internal:${host_port}"
    echo "[INFO] Using serverlb for API server: $api_server"
  else
    # kind: 使用 kubeconfig 中的地址，若为 127.0.0.1 或 0.0.0.0 则改为 host.k3d.internal
    api_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${context_name}')].cluster.server}")
    api_server=${api_server/127.0.0.1/host.k3d.internal}
    api_server=${api_server/0.0.0.0/host.k3d.internal}
  fi

  # 获取 CA 证书
  local ca_data
  ca_data=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${context_name}')].cluster.certificate-authority-data}")

  # 创建 ServiceAccount 用于 ArgoCD 访问
  echo "[INFO] Creating argocd-manager ServiceAccount in ${context_name}..."
  kubectl --context "${context_name}" create namespace argocd 2> /dev/null || true

  cat << EOF | kubectl --context "${context_name}" apply -f -
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
  cat << EOF | kubectl --context "${context_name}" apply -f -
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
  local token
  token=$(kubectl --context "${context_name}" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)

  if [[ -z "$token" ]]; then
    echo "[ERROR] Failed to get ServiceAccount token"
    return 1
  fi

  # 创建 ArgoCD cluster secret with labels and annotations
  echo "[INFO] Creating ArgoCD cluster secret with metadata..."
  insecure=true

  # 构建 labels 和 annotations
  local cluster_type="business"
  if [[ "$cluster_name" == "devops" ]]; then
    cluster_type="management"
  fi

  # 始终添加 annotations（即使为空），以便 ApplicationSet 可以解析
  local annotations="
    portainer-edge-id: \"$edge_id\"
    portainer-edge-key: \"$edge_key\""

  if [[ "$provider" == "k3d" ]]; then
    cat << EOF | kubectl --context k3d-devops apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster_name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: ${cluster_name}
    provider: ${provider}
    type: ${cluster_type}
  annotations:${annotations}
type: Opaque
stringData:
  name: ${cluster_name}
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
    cat << EOF | kubectl --context k3d-devops apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster_name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: ${cluster_name}
    provider: ${provider}
    type: ${cluster_type}
  annotations:${annotations}
type: Opaque
stringData:
  name: ${cluster_name}
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

  echo "[SUCCESS] Cluster ${cluster_name} registered to ArgoCD with labels: env=${cluster_name}, provider=${provider}, type=${cluster_type}"
  if [[ -n "$edge_id" ]]; then
    echo "[INFO] Portainer credentials added as annotations"
  fi
  echo "[INFO] Verify with: kubectl --context k3d-devops get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster"
}

register_cluster_kubectl() {
  local cluster_name="$1"
  local provider="${2:-k3d}"
  local max_attempts="${ARGOCD_REGISTER_MAX_RETRIES:-3}"
  local delay="${ARGOCD_REGISTER_BACKOFF:-10}"
  local attempt=1 rc=0

  while [ $attempt -le $max_attempts ]; do
    if register_cluster_once "$cluster_name" "$provider"; then
      return 0
    fi
    rc=$?
    if [ $attempt -lt $max_attempts ]; then
      echo "[WARN] ArgoCD registration failed for $cluster_name (exit=$rc, attempt $attempt/$max_attempts); retrying in ${delay}s..." >&2
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  echo "[ERROR] ArgoCD registration failed after $max_attempts attempt(s) for $cluster_name" >&2
  return $rc
}

unregister_cluster_kubectl() {
  local cluster_name="$1"
  local provider="${2:-k3d}"

  local context_name
  if [[ "$provider" == "k3d" ]]; then
    context_name="k3d-${cluster_name}"
  else
    context_name="kind-${cluster_name}"
  fi

  echo "[INFO] Unregistering cluster ${cluster_name} from ArgoCD..."

  # 删除 ArgoCD cluster secret
  kubectl --context k3d-devops delete secret "cluster-${cluster_name}" -n argocd --ignore-not-found=true

  # 删除集群中的 ServiceAccount 和 RBAC
  if kubectl config get-contexts "${context_name}" &> /dev/null; then
    kubectl --context "${context_name}" delete clusterrolebinding argocd-manager-role-binding --ignore-not-found=true
    kubectl --context "${context_name}" delete clusterrole argocd-manager-role --ignore-not-found=true
    kubectl --context "${context_name}" delete serviceaccount argocd-manager -n kube-system --ignore-not-found=true
    kubectl --context "${context_name}" delete secret argocd-manager-token -n kube-system --ignore-not-found=true
  fi

  echo "[SUCCESS] Cluster ${cluster_name} unregistered from ArgoCD"
}

# Main logic
action="${1:-register}"
cluster_name="${2:-}"
provider="${3:-k3d}"

if [[ -z "$cluster_name" ]]; then
  echo "Usage: $0 <register|unregister> <cluster_name> [provider]" >&2
  echo "Example: $0 register dev-k3d k3d" >&2
  echo "Example: $0 unregister dev-k3d" >&2
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
    echo "[ERROR] Unknown action: $action" >&2
    echo "Usage: $0 <register|unregister> <cluster_name> [provider]" >&2
    exit 1
    ;;
esac
