#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# 参数解析：默认不清理 devops 集群
CLEAN_DEVOPS=0
VERIFY=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --all|--include-devops)
      CLEAN_DEVOPS=1
      shift
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--all|--include-devops] [--verify]" >&2
      echo "  --all: Clean everything including devops cluster" >&2
      echo "  --verify: Verify environment is clean after cleanup" >&2
      echo "  (default): Clean only business clusters, keep devops" >&2
      exit 1
      ;;
  esac
done

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "[DRY-RUN][CLEAN] 将执行:"
  echo "  - 终止 kubectl port-forward"
  if [ "$CLEAN_DEVOPS" = "1" ]; then
    echo "  - 停止并移除 Portainer/HAProxy (compose) 与命名卷"
    echo "  - 删除所有集群（包括 devops 管理集群）"
  else
    echo "  - 保留 Portainer/HAProxy 和 devops 集群"
    echo "  - 删除业务集群"
  fi
  echo "  - 移除各集群中的 Edge Agent 命名空间"
  echo "  - 清理遗留 k3d/kind 集群、数据目录、网络连接/网络"
  echo "  - 清理 Portainer Endpoint（避免重名）"
  echo "  - 重置 haproxy.cfg 动态路由区块"
  echo "  - 清理 kubeconfig 中的相关 context/cluster"
  exit 0
fi

echo "[CLEAN] Killing port-forwards..."
pgrep -af "kubectl.*port-forward" | awk '{print $1}' | xargs -r kill -9 || true

echo "[CLEAN] Ensuring Portainer is running for endpoint cleanup..."
# 确保Portainer在endpoint清理时是运行的
if ! docker ps --format '{{.Names}}' | grep -q '^portainer-ce$'; then
  echo "[CLEAN] Starting Portainer temporarily for cleanup..."
  docker start portainer-ce 2>/dev/null || true
  sleep 5  # 等待Portainer启动
fi

echo "[CLEAN] Deleting Portainer endpoints..."
# 在停止 Portainer 前，通过 API 删除所有 Edge 端点，避免后续重名
if docker ps --format '{{.Names}}' | grep -q '^portainer-ce$'; then
  # 从数据库读取集群列表（优先）
  if kubectl --context k3d-devops -n paas exec postgresql-0 -- \
       psql -U kindler -d kindler -c "SELECT 1" >/dev/null 2>&1; then
    kubectl --context k3d-devops -n paas exec postgresql-0 -- \
      psql -U kindler -d kindler -t -c "SELECT name FROM clusters" 2>/dev/null | \
      while read -r env; do
        env=$(echo "$env" | xargs)  # trim whitespace
        [ -n "$env" ] || continue
        ep=$(echo "$env" | tr -d '-')
        "$ROOT_DIR/scripts/portainer.sh" del-endpoint "$ep" >/dev/null 2>&1 || true
      done
  elif [ -f "$ROOT_DIR/config/environments.csv" ]; then
    # Fallback to CSV
    awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" | while read -r env; do
      [ -n "$env" ] || continue
      ep=$(echo "$env" | tr -d '-')
      "$ROOT_DIR/scripts/portainer.sh" del-endpoint "$ep" >/dev/null 2>&1 || true
    done
  fi
  # 额外清理 devops 端点
  "$ROOT_DIR/scripts/portainer.sh" del-endpoint devops >/dev/null 2>&1 || true
fi

if [ "$CLEAN_DEVOPS" = "1" ]; then
  echo "[CLEAN] Stopping infrastructure (Portainer + HAProxy)..."
  docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" down -v --timeout 0 || true

  echo "[CLEAN] Force stopping Portainer containers..."
  docker stop --timeout 0 portainer-ce >/dev/null 2>&1 || true
  docker rm -f portainer-ce >/dev/null 2>&1 || true

  echo "[CLEAN] Force stopping HAProxy containers..."
  docker stop --timeout 0 haproxy-gw >/dev/null 2>&1 || true
  docker rm -f haproxy-gw >/dev/null 2>&1 || true

  echo "[CLEAN] Removing all Portainer and infrastructure volumes..."
  docker volume ls -q | grep -E 'portainer|infrastructure' | xargs -r docker volume rm -f 2>/dev/null || true
else
  echo "[CLEAN] Skipping Portainer/HAProxy cleanup (use --all to clean)"
fi

echo "[CLEAN] Cleaning Portainer Edge agents from clusters..."
for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -E '^k3d-|^kind-'); do
  kubectl --context="$ctx" delete namespace portainer-edge --ignore-not-found=true --timeout=10s >/dev/null 2>&1 || true
done

echo "[CLEAN] Reset haproxy.cfg dynamic sections..."
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
if [ -f "$CFG" ]; then
  tmp=$(mktemp)
  awk '
    BEGIN{in_dyn_acl=0; in_dyn_be=0}
    {
      if ($0 ~ /# BEGIN DYNAMIC ACL/) {print $0; in_dyn_acl=1; next}
      if (in_dyn_acl && $0 ~ /# END DYNAMIC ACL/) {print $0; in_dyn_acl=0; next}
      if (in_dyn_acl) {next}
      if ($0 ~ /# BEGIN DYNAMIC BACKENDS/) {print $0; in_dyn_be=1; next}
      if (in_dyn_be && $0 ~ /# END DYNAMIC BACKENDS/) {print $0; in_dyn_be=0; next}
      if (in_dyn_be) {next}
      print $0
    }
  ' "$CFG" >"$tmp" && mv "$tmp" "$CFG" || true
fi

if [ "$CLEAN_DEVOPS" = "0" ]; then
  echo "[CLEAN] Deleting business clusters only (keeping devops)..."
else
  echo "[CLEAN] Deleting all clusters (including devops)..."
fi

if [ -f "$ROOT_DIR/config/clusters.env" ]; then . "$ROOT_DIR/config/clusters.env"; fi

delete_one() {
  local n="$1" p="$2"
  local max_retry=3
  local i=0
  local success=0
  
  while [ $i -lt $max_retry ]; do
    case "$p" in
      k3d) 
        if k3d cluster delete "$n" 2>&1; then
          echo "[CLEAN] ✓ Deleted k3d cluster: $n"
          success=1
          break
        fi
        ;;
      *)   
        if kind delete cluster --name "$n" 2>&1; then
          echo "[CLEAN] ✓ Deleted kind cluster: $n"
          success=1
          break
        fi
        ;;
    esac
    i=$((i+1))
    [ $i -lt $max_retry ] && sleep 2
  done
  
  if [ $success -eq 0 ]; then
    echo "[CLEAN] ✗ Failed to delete cluster after $max_retry retries: $n (ignoring)"
  fi
  
  return 0  # 总是返回成功，避免整个清理流程中断
}

# from PostgreSQL database (primary source)
if kubectl --context k3d-devops -n paas exec postgresql-0 -- \
     psql -U kindler -d kindler -c "SELECT 1" >/dev/null 2>&1; then
  echo "[CLEAN] Reading clusters from PostgreSQL database..."
  
  if [ "$CLEAN_DEVOPS" = "0" ]; then
    # 过滤掉 devops 集群
    kubectl --context k3d-devops -n paas exec postgresql-0 -- \
      psql -U kindler -d kindler -t -c "SELECT name, provider FROM clusters WHERE name != 'devops' ORDER BY name" 2>/dev/null | \
      while IFS='|' read -r n p; do
        n=$(echo "$n" | xargs)  # trim whitespace
        p=$(echo "$p" | xargs)
        [ -n "$n" ] || continue
        [ -n "$p" ] || p=kind
        delete_one "$n" "$p"
      done
  else
    # 删除所有集群（包括 devops）
    kubectl --context k3d-devops -n paas exec postgresql-0 -- \
      psql -U kindler -d kindler -t -c "SELECT name, provider FROM clusters ORDER BY name" 2>/dev/null | \
      while IFS='|' read -r n p; do
        n=$(echo "$n" | xargs)
        p=$(echo "$p" | xargs)
        [ -n "$n" ] || continue
        [ -n "$p" ] || p=kind
        delete_one "$n" "$p"
      done
  fi
else
  echo "[CLEAN] PostgreSQL not available, falling back to CSV..."
  # Fallback to CSV if database is not available
  if [ -f "$ROOT_DIR/config/environments.csv" ]; then
    if [ "$CLEAN_DEVOPS" = "0" ]; then
      awk -F, '$0 !~ /^\s*#/ && NF>0 && $1!="devops" {print $1","$2}' "$ROOT_DIR/config/environments.csv" | while IFS=, read -r n p; do
        [ -n "$n" ] || continue
        [ -n "$p" ] || p=kind
        delete_one "$n" "$p"
      done
    else
      awk -F, '$0 !~ /^\s*#/ && NF>0 {print $1","$2}' "$ROOT_DIR/config/environments.csv" | while IFS=, read -r n p; do
        [ -n "$n" ] || continue
        [ -n "$p" ] || p=kind
        delete_one "$n" "$p"
      done
    fi
  else
    echo "[CLEAN] No CSV file found either, skipping CSV-based cleanup"
  fi
fi

# Load Git configuration for branch cleanup
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
fi

# also attempt defaults (exclude devops if CLEAN_DEVOPS=0)
for n in dev uat prod ops; do
  up="$(echo "$n" | tr '[:lower:]' '[:upper:]')"
  pvar="PROVIDER_${up}"; nvar="CLUSTER_${up}"
  provider="${!pvar:-kind}"; name="${!nvar:-$n}"
  delete_one "$name" "$provider"
done

# Delete devops management cluster only if CLEAN_DEVOPS=1
if [ "$CLEAN_DEVOPS" = "1" ]; then
  echo "[CLEAN] Deleting devops management cluster..."
  k3d cluster delete devops 2>&1 || true
else
  echo "[CLEAN] Keeping devops management cluster"
fi

# Force cleanup any remaining k3d/kind clusters
if [ "$CLEAN_DEVOPS" = "1" ]; then
  echo "[CLEAN] Force cleanup all remaining clusters..."
  k3d cluster list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null | while read -r cluster; do
    [ -n "$cluster" ] && k3d cluster delete "$cluster" 2>&1 || true
  done
  kind get clusters 2>/dev/null | while read -r cluster; do
    [ -n "$cluster" ] && kind delete cluster --name "$cluster" 2>&1 || true
  done
else
  echo "[CLEAN] Force cleanup business clusters only..."
  k3d cluster list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null | while read -r cluster; do
    [ -n "$cluster" ] && [ "$cluster" != "devops" ] && k3d cluster delete "$cluster" 2>&1 || true
  done
  kind get clusters 2>/dev/null | while read -r cluster; do
    [ -n "$cluster" ] && kind delete cluster --name "$cluster" 2>&1 || true
  done
fi

echo "[CLEAN] Cleanup related kubeconfig contexts/clusters..."
if command -v kubectl >/dev/null 2>&1; then
  if [ "$CLEAN_DEVOPS" = "1" ]; then
    # 清理所有 k3d 和 kind contexts
    kubectl config get-contexts -o name 2>/dev/null | grep -E '^(k3d-|kind-)' | while read -r ctx; do
      kubectl config delete-context "$ctx" >/dev/null 2>&1 || true
    done || true
    # 清理所有 k3d 和 kind clusters
    kubectl config get-clusters 2>/dev/null | grep -E '^(k3d-|kind-)' | while read -r cluster; do
      kubectl config delete-cluster "$cluster" >/dev/null 2>&1 || true
    done || true
    # 清理所有 k3d 用户
    kubectl config view -o jsonpath='{.users[*].name}' 2>/dev/null | tr ' ' '\n' | grep '^k3d-' | while read -r user; do
      kubectl config unset "users.$user" >/dev/null 2>&1 || true
    done || true
  else
    # 只清理业务集群的 contexts（保留 devops）
    kubectl config get-contexts -o name 2>/dev/null | grep -E '^(k3d-|kind-)' | grep -v 'devops' | while read -r ctx; do
      kubectl config delete-context "$ctx" >/dev/null 2>&1 || true
    done || true
    kubectl config get-clusters 2>/dev/null | grep -E '^(k3d-|kind-)' | grep -v 'devops' | while read -r cluster; do
      kubectl config delete-cluster "$cluster" >/dev/null 2>&1 || true
    done || true
  fi
fi

echo "[CLEAN] Removing generated data..."
rm -rf "$ROOT_DIR/data" || true
mkdir -p "$ROOT_DIR/data"

echo "[CLEAN] Disconnecting Portainer from K3D networks..."
for net in $(docker network ls --format '{{.Name}}' | grep '^k3d-'); do
  docker network disconnect "$net" portainer-ce 2>/dev/null || true
done

echo "[CLEAN] Removing infrastructure network..."
remove_network() {
  local net="$1"
  # disconnect any attached containers first (avoid Resource is still in use)
  if docker network inspect "$net" >/dev/null 2>&1; then
    for c in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null); do
      [ -n "$c" ] && docker network disconnect -f "$net" "$c" >/dev/null 2>&1 || true
    done
    docker network rm "$net" >/dev/null 2>&1 || true
  fi
}

# Remove infrastructure and management networks
remove_network infrastructure
remove_network management

# Remove k3d cluster networks (k3d-<name>)
echo "[CLEAN] Removing k3d cluster networks..."
if [ "$CLEAN_DEVOPS" = "1" ]; then
  # Clean all k3d networks including k3d-shared
  echo "[CLEAN] Removing all k3d networks (including k3d-shared)..."
  for net in $(docker network ls --format '{{.Name}}' | grep '^k3d-'); do
    remove_network "$net"
  done
else
  # Clean only business cluster networks, keep k3d-shared for devops
  echo "[CLEAN] Removing business cluster networks (keeping k3d-shared)..."
  for net in $(docker network ls --format '{{.Name}}' | grep '^k3d-' | grep -v '^k3d-shared$' | grep -v '^k3d-devops$'); do
    echo "[CLEAN] Removing network: $net"
    remove_network "$net"
  done
fi

# Remove kind network (if no kind clusters remain)
if [ "$CLEAN_DEVOPS" = "1" ] || [ "$(kind get clusters 2>/dev/null | wc -l)" -eq 0 ]; then
  remove_network kind
fi

echo "[CLEAN] Done."

# 验证清理完整性（如果指定了 --verify）
if [ "$VERIFY" = "1" ]; then
  echo "[VERIFY] Checking cleanup completeness..."
  errors=0
  
  # 检查集群容器
  if [ "$CLEAN_DEVOPS" = "1" ]; then
    remaining_containers=$(docker ps -a --format '{{.Names}}' | grep -E '^(k3d-|kind-|portainer-ce|haproxy-gw)' || true)
    if [ -n "$remaining_containers" ]; then
      echo "[VERIFY] ✗ Found remaining containers:" >&2
      echo "$remaining_containers" | sed 's/^/  - /' >&2
      errors=$((errors+1))
    else
      echo "[VERIFY] ✓ No cluster/infrastructure containers"
    fi
  else
    remaining_containers=$(docker ps -a --format '{{.Names}}' | grep -E '^(k3d-|kind-)' | grep -v 'devops' || true)
    if [ -n "$remaining_containers" ]; then
      echo "[VERIFY] ✗ Found remaining business cluster containers:" >&2
      echo "$remaining_containers" | sed 's/^/  - /' >&2
      errors=$((errors+1))
    else
      echo "[VERIFY] ✓ No business cluster containers (devops preserved)"
    fi
  fi
  
  # 检查卷
  if [ "$CLEAN_DEVOPS" = "1" ]; then
    remaining_volumes=$(docker volume ls -q | grep -E 'portainer|infrastructure' || true)
    if [ -n "$remaining_volumes" ]; then
      echo "[VERIFY] ✗ Found remaining volumes:" >&2
      echo "$remaining_volumes" | sed 's/^/  - /' >&2
      errors=$((errors+1))
    else
      echo "[VERIFY] ✓ No Portainer/infrastructure volumes"
    fi
  fi
  
  # 检查网络
  if [ "$CLEAN_DEVOPS" = "1" ]; then
    remaining_networks=$(docker network ls --format '{{.Name}}' | grep -E '^(k3d-|infrastructure)' || true)
    if [ -n "$remaining_networks" ]; then
      echo "[VERIFY] ✗ Found remaining networks:" >&2
      echo "$remaining_networks" | sed 's/^/  - /' >&2
      errors=$((errors+1))
    else
      echo "[VERIFY] ✓ No cluster/infrastructure networks"
    fi
  fi
  
  # 检查 kubeconfig
  if command -v kubectl >/dev/null 2>&1; then
    if [ "$CLEAN_DEVOPS" = "1" ]; then
      remaining_contexts=$(kubectl config get-contexts -o name 2>/dev/null | grep -E '^(k3d-|kind-)' || true)
      if [ -n "$remaining_contexts" ]; then
        echo "[VERIFY] ✗ Found remaining kubeconfig contexts:" >&2
        echo "$remaining_contexts" | sed 's/^/  - /' >&2
        errors=$((errors+1))
      else
        echo "[VERIFY] ✓ No cluster contexts in kubeconfig"
      fi
    else
      remaining_contexts=$(kubectl config get-contexts -o name 2>/dev/null | grep -E '^(k3d-|kind-)' | grep -v 'devops' || true)
      if [ -n "$remaining_contexts" ]; then
        echo "[VERIFY] ✗ Found remaining business cluster contexts:" >&2
        echo "$remaining_contexts" | sed 's/^/  - /' >&2
        errors=$((errors+1))
      else
        echo "[VERIFY] ✓ No business cluster contexts (devops preserved)"
      fi
    fi
  fi
  
  # 检查数据库记录
  if kubectl --context k3d-devops -n paas exec postgresql-0 -- \
       psql -U kindler -d kindler -c "SELECT 1" >/dev/null 2>&1; then
    if [ "$CLEAN_DEVOPS" = "0" ]; then
      db_count=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
        psql -U kindler -d kindler -t -c "SELECT COUNT(*) FROM clusters WHERE name != 'devops'" 2>/dev/null | xargs || echo "0")
      if [ "$db_count" -gt 0 ]; then
        echo "[VERIFY] ✗ Database still has $db_count business cluster record(s)" >&2
        kubectl --context k3d-devops -n paas exec postgresql-0 -- \
          psql -U kindler -d kindler -t -c "SELECT name FROM clusters WHERE name != 'devops'" 2>/dev/null | \
          sed 's/^/  - /' >&2
        errors=$((errors+1))
      else
        echo "[VERIFY] ✓ No business cluster records in database (devops preserved)"
      fi
    else
      db_count=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
        psql -U kindler -d kindler -t -c "SELECT COUNT(*) FROM clusters" 2>/dev/null | xargs || echo "0")
      if [ "$db_count" -gt 0 ]; then
        echo "[VERIFY] ⚠ Database still has $db_count cluster record(s) (devops cluster still running)"
      fi
    fi
  fi
  
  if [ $errors -eq 0 ]; then
    echo "[VERIFY] ✓ Environment is clean"
    exit 0
  else
    echo "[VERIFY] ✗ Found $errors issue(s)" >&2
    exit 1
  fi
fi
