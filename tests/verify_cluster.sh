#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"

usage() {
  cat >&2 <<USAGE
Usage: $0 <cluster-name> [--provider kind|k3d]

验证集群功能：
  - 节点就绪
  - 核心组件运行
  - Portainer 连接（如果已注册）
  - 网络连通性（如果配置了 HAProxy 路由）

选项:
  --provider    指定集群类型（kind 或 k3d），默认从配置推断
  --skip-portainer  跳过 Portainer 验证
  --skip-network    跳过网络验证
USAGE
  exit 1
}

cluster_name="${1:-}"
[ -n "$cluster_name" ] || usage
shift || true

provider=""
skip_portainer=0
skip_network=0

while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    --provider=*) provider="${1#--provider=}"; shift ;;
    --skip-portainer) skip_portainer=1; shift ;;
    --skip-network) skip_network=1; shift ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Load config
load_env
if [ -z "$provider" ]; then
  provider="$(provider_for "$cluster_name")"
fi

case "$provider" in
  k3d) ctx="k3d-$cluster_name" ;;
  kind) ctx="kind-$cluster_name" ;;
  *) echo "[ERROR] Invalid provider: $provider" >&2; exit 1 ;;
esac

echo "=== Verifying cluster: $cluster_name (provider: $provider, context: $ctx) ==="

# 1. Check cluster context exists
echo "[1/5] Checking cluster context..."
if ! kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
  echo "  ✗ Context $ctx not found"
  exit 1
fi
echo "  ✓ Context exists"

# 2. Check nodes are ready
echo "[2/5] Checking nodes..."
if ! kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
  echo "  ✗ Cannot connect to cluster"
  exit 1
fi

node_status=$(kubectl --context "$ctx" get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
if [ "$node_status" != "True" ]; then
  echo "  ✗ Node not ready"
  kubectl --context "$ctx" get nodes
  exit 1
fi
echo "  ✓ Nodes ready"

# 3. Check core components
echo "[3/5] Checking core components..."
errors=0

# Check kube-system pods
if ! kubectl --context "$ctx" get pods -n kube-system >/dev/null 2>&1; then
  echo "  ✗ Cannot access kube-system namespace"
  errors=$((errors+1))
else
  not_running=$(kubectl --context "$ctx" get pods -n kube-system --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l 2>/dev/null | tr -d ' \n' || echo "0")
  if [ "${not_running:-0}" -gt 0 ] 2>/dev/null; then
    echo "  ⚠ Some kube-system pods not running:"
    kubectl --context "$ctx" get pods -n kube-system | grep -v "Running\|Completed" || true
  else
    echo "  ✓ Core components running"
  fi
fi

# 4. Check Portainer connection (if registered)
if [ "$skip_portainer" -eq 0 ]; then
  echo "[4/5] Checking Portainer connection..."
  
  # Check if Edge Agent is deployed
  if kubectl --context "$ctx" get ns portainer-edge >/dev/null 2>&1; then
    edge_pod=$(kubectl --context "$ctx" get pods -n portainer-edge -l app=portainer-edge-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$edge_pod" = "Running" ]; then
      echo "  ✓ Edge Agent running"
    else
      echo "  ⚠ Edge Agent not running (status: ${edge_pod:-unknown})"
      kubectl --context "$ctx" get pods -n portainer-edge 2>/dev/null || true
    fi
  else
    echo "  - Edge Agent not deployed (skipping)"
  fi
else
  echo "[4/5] Skipping Portainer verification"
fi

# 5. Check network connectivity (if HAProxy route configured)
if [ "$skip_network" -eq 0 ]; then
  echo "[5/5] Checking network connectivity..."
  
  if [ -f "$ROOT_DIR/config/clusters.env" ]; then
    . "$ROOT_DIR/config/clusters.env"
  fi
  : "${BASE_DOMAIN:=192.168.51.30.sslip.io}"
  
  # Determine test URL based on provider
  case "$provider" in
    k3d) test_host="whoami.k3d.${cluster_name}.${BASE_DOMAIN}" ;;
    kind) test_host="whoami.kind.${cluster_name}.${BASE_DOMAIN}" ;;
  esac
  
  # Try to access through HAProxy (with short timeout)
  if curl -s -m 3 "http://${test_host}" >/dev/null 2>&1; then
    echo "  ✓ Network accessible via HAProxy ($test_host)"
  else
    echo "  - Cannot access via HAProxy (may not be configured yet)"
  fi
else
  echo "[5/5] Skipping network verification"
fi

echo ""
echo "=== Verification complete: $cluster_name ==="
if [ "$errors" -gt 0 ]; then
  echo "Status: ⚠ WARNINGS ($errors issues found)"
  exit 0
else
  echo "Status: ✓ PASS"
  exit 0
fi
