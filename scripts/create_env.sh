#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib.sh"
. "$ROOT_DIR/scripts/lib_db.sh"

usage() {
  cat >&2 <<USAGE
Usage: $0 -n <name> [-p kind|k3d] [--node-port <port>] [--pf-port <port>] \
            [--register-portainer|--no-register-portainer] [--haproxy-route|--no-haproxy-route] \
            [--register-argocd|--no-register-argocd] [--pf-host <addr>] [--force]

说明：
- 默认参数可从 \`config/environments.csv\` 中读取（按环境名匹配），命令行传参可覆盖 CSV 默认。
- CSV 列：env,provider,node_port,pf_port,register_portainer,haproxy_route
- --force: 跳过 CSV 验证，允许创建不在配置清单中的集群（用于测试）
USAGE
  exit 1
}

name=""; provider=""; reg_portainer=1; add_haproxy=1; reg_argocd=1
pf_host_override=""; node_port=30080; pf_port=""
force_create=0  # 强制创建模式（跳过 CSV 验证）
# 追踪命令行明确设置的参数
cmd_reg_portainer=""; cmd_add_haproxy=""

trim() { sed -e 's/^\s\+//' -e 's/\s\+$//' ; }
to_lower() { tr 'A-Z' 'a-z'; }
parse_bool() { v=$(echo "$1" | to_lower); case "$v" in 1|y|yes|true|on) echo 1;; 0|n|no|false|off) echo 0;; *) echo 0;; esac; }

# 从数据库加载配置（优先级高于 CSV）
load_db_defaults() {
  local n="$1"
  # 检查数据库是否可用
  if ! db_is_available 2>/dev/null; then
    return 1  # 数据库不可用，回退到 CSV
  fi
  
  # 查询集群记录
  local record
  record=$(db_get_cluster "$n" 2>/dev/null) || return 1
  [ -n "$record" ] || return 1
  
  # 解析记录：name|provider|subnet|node_port|pf_port|http_port|https_port
  IFS='|' read -r db_name db_provider db_subnet db_node_port db_pf_port db_http_port db_https_port <<EOF
$record
EOF
  
  # 应用配置（如果命令行未指定）
  [ -z "$provider" ] && [ -n "$db_provider" ] && provider="$db_provider"
  [ -z "$pf_port" ] && [ -n "$db_pf_port" ] && pf_port="$db_pf_port"
  [ "$node_port" = 30080 ] && [ -n "$db_node_port" ] && node_port="$db_node_port"
  
  echo "[INFO] Loaded configuration from database"
  return 0
}

load_csv_defaults() {
  local n="$1" csv="$ROOT_DIR/config/environments.csv"
  [ -f "$csv" ] || return 0
  # skip comments and blank lines; pick line where first column equals env name
  local line
  line=$(awk -F, -v n="$n" 'BEGIN{IGNORECASE=0} $0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print; exit}' "$csv" | tr -d '\r') || true
  [ -n "$line" ] || return 0
  IFS=, read -r c_env c_provider c_node_port c_pf_port c_reg_portainer c_haproxy_route <<EOF
$line
EOF
  c_provider=$(echo "${c_provider:-}" | trim)
  c_node_port=$(echo "${c_node_port:-}" | trim)
  c_pf_port=$(echo "${c_pf_port:-}" | trim)
  c_reg_portainer=$(echo "${c_reg_portainer:-}" | trim)
  c_haproxy_route=$(echo "${c_haproxy_route:-}" | trim)
  [ -z "$provider" ] && [ -n "${c_provider:-}" ] && provider="$c_provider"
  [ -z "$pf_port" ] && [ -n "${c_pf_port:-}" ] && pf_port="$c_pf_port"
  if [ "$node_port" = 30080 ] && [ -n "${c_node_port:-}" ]; then node_port="$c_node_port"; fi
  # 只有当命令行未明确设置时才使用CSV配置（保持命令行参数优先级）
  if [ -z "$cmd_reg_portainer" ] && [ -n "${c_reg_portainer:-}" ]; then
    reg_portainer=$(parse_bool "$c_reg_portainer")
  fi
  if [ -z "$cmd_add_haproxy" ] && [ -n "${c_haproxy_route:-}" ]; then
    add_haproxy=$(parse_bool "$c_haproxy_route")
  fi
}

# parse short opts first
while getopts ":n:p:-:" opt; do
  case "$opt" in
    n) name="$OPTARG" ;;
    p) provider="$OPTARG" ;;
    -)
      case "$OPTARG" in
        register-portainer) reg_portainer=1; cmd_reg_portainer=1 ;;
        no-register-portainer) reg_portainer=0; cmd_reg_portainer=0 ;;
        haproxy-route) add_haproxy=1; cmd_add_haproxy=1 ;;
        no-haproxy-route) add_haproxy=0; cmd_add_haproxy=0 ;;
        register-argocd) reg_argocd=1 ;;
        no-register-argocd) reg_argocd=0 ;;
        force) force_create=1 ;;
        node-port)
          node_port="${!OPTIND}"; OPTIND=$((OPTIND+1)) ;;
        node-port=*) node_port="${OPTARG#node-port=}" ;;
        pf-port)
          pf_port="${!OPTIND}"; OPTIND=$((OPTIND+1)) ;;
        pf-port=*) pf_port="${OPTARG#pf-port=}" ;;
        pf-host)
          pf_host_override="${!OPTIND}"; OPTIND=$((OPTIND+1)) ;;
        pf-host=*) pf_host_override="${OPTARG#pf-host=}" ;;
        *) usage ;;
      esac ;;
    *) usage ;;
  esac
done
[ -z "$name" ] && usage

# 验证环境名是否在配置清单中（如果CSV存在且未使用 --force）
if [ "$force_create" = 0 ] && [ -f "$ROOT_DIR/config/environments.csv" ]; then
  # 检查环境名是否在CSV中
  if ! awk -F, -v n="$name" '$0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {found=1; exit} END{exit !found}' "$ROOT_DIR/config/environments.csv"; then
    echo "错误：环境名 '$name' 不在 config/environments.csv 配置清单中" >&2
    echo "可用环境：" >&2
    awk -F, '$0 !~ /^[[:space:]]*#/ && NF>0 {print "  " $1}' "$ROOT_DIR/config/environments.csv" >&2
    echo "" >&2
    echo "提示：使用 --force 参数可跳过此验证（用于测试）" >&2
    exit 1
  fi
fi

# 如果使用 --force 模式，显示警告
if [ "$force_create" = 1 ]; then
  echo "[WARN] Force mode enabled: skipping CSV validation"
  echo "[INFO] Creating temporary cluster '$name' with provider '$provider'"
fi

# Load defaults: 优先数据库，回退到 CSV
if ! load_db_defaults "$name"; then
  echo "[INFO] Database not available or cluster not found, falling back to CSV"
  load_csv_defaults "$name"
fi

if [ -z "$provider" ]; then
  load_env
  # 使用provider_for函数而不是直接构造环境变量名
  provider="$(provider_for "$name")"
fi

case "$provider" in
  kind|k3d) : ;;
  *) echo "Invalid provider: $provider (use kind|k3d)" >&2; exit 2 ;;
esac

echo "[CREATE] $name via $provider (node-port=$node_port, reg_portainer=$reg_portainer, haproxy=$add_haproxy)"
if ! PROVIDER="$provider" "$ROOT_DIR"/scripts/cluster.sh create "$name"; then
  echo "[CREATE] cluster '$name' already exists or create failed; continuing" >&2
fi

ctx_prefix=$([ "$provider" = "k3d" ] && echo k3d || echo kind)
ctx="$ctx_prefix-$name"

# 预加载关键系统镜像到 k3d 集群（必须在任何 pod 部署前）
if [ "$provider" = "k3d" ]; then
  echo "[K3D] Preloading critical system and Traefik images to avoid network pull failures..."
  . "$ROOT_DIR/scripts/lib.sh"
  
  # 基础设施镜像（pause, coredns）
  prefetch_image rancher/mirrored-pause:3.6 || echo "[WARN] Failed to prefetch pause image"
  prefetch_image rancher/mirrored-coredns-coredns:1.12.0 || echo "[WARN] Failed to prefetch coredns image"
  
  # k3d 内置 Traefik 所需镜像（klipper-helm 和 traefik）
  # 这些镜像是 k3d 自动部署 Traefik 时需要的
  prefetch_image rancher/klipper-helm:v0.9.3-build20241008 || echo "[WARN] Failed to prefetch klipper-helm image"
  prefetch_image rancher/mirrored-library-traefik:2.11.18 || echo "[WARN] Failed to prefetch traefik image"
  
  echo "[K3D] Importing system and Traefik images to cluster..."
  k3d image import \
    rancher/mirrored-pause:3.6 \
    rancher/mirrored-coredns-coredns:1.12.0 \
    rancher/klipper-helm:v0.9.3-build20241008 \
    rancher/mirrored-library-traefik:2.11.18 \
    -c "$name" 2>&1 | grep -v "INFO" || echo "[WARN] Failed to import some images"
  
  echo "[K3D] All critical images imported successfully"
fi

# Ensure Traefik (NodePort ingress) on all clusters (idempotent, fast path)
. "$ROOT_DIR/scripts/lib.sh"
if [ "$provider" = "kind" ]; then
  preload_image_to_cluster kind "$name" "traefik:v2.10" || true
  preload_image_to_cluster kind "$name" "traefik/whoami:v1.10.2" || true
else
  # optional: preload into k3d to speed up rollout
  preload_image_to_cluster k3d "$name" "traefik:v2.10" || true
  preload_image_to_cluster k3d "$name" "traefik/whoami:v1.10.2" || true
fi
need_apply_traefik=1
if kubectl --context "$ctx" get ns traefik >/dev/null 2>&1; then
  # If service exists and has a nodePort, skip reinstall
  np=$(kubectl --context "$ctx" -n traefik get svc traefik -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
  if [ -n "$np" ]; then
    echo "[TRAEFIK] exists (nodePort=$np), skip apply"
    need_apply_traefik=0
  fi
fi
if [ "$need_apply_traefik" -eq 1 ]; then
  echo "[TRAEFIK] install/update..."
  "$ROOT_DIR"/scripts/traefik.sh install "$ctx" --nodeport "$node_port" || true
fi

# 连接 devops 集群到业务集群网络（k3d 独立子网）
if [ "$provider" = "k3d" ] && [ "$name" != "devops" ]; then
  subnet=$(subnet_for "$name")
  if [ -n "$subnet" ]; then
    dedicated_network="k3d-${name}"
    echo "[NETWORK] Connecting devops cluster to $dedicated_network..."
    docker network connect "$dedicated_network" k3d-devops-server-0 2>/dev/null || true
    echo "[NETWORK] devops can now access $name cluster"
  fi
fi

# Add HAProxy route (domain-based; default to node_port)
if [ $add_haproxy -eq 1 ]; then
  echo "[HAPROXY] Adding route for cluster $name..."
  if ! "$ROOT_DIR"/scripts/haproxy_route.sh add "$name" --node-port "$node_port"; then
    echo "[ERROR] Failed to add HAProxy route for $name"
    exit 1
  fi
  echo "[HAPROXY] Route added successfully"
fi

if [ $reg_portainer -eq 1 ]; then
  # 使用 Edge Agent 方式（更可靠，不依赖网络镜像拉取）
  echo "[PORTAINER] Using Edge Agent mode (recommended for offline environments)"

  # 预拉取镜像并导入到集群（本地有则跳过）
  if [ "${DRY_RUN:-}" != "1" ]; then
    echo "[PORTAINER] Prefetching required images (skip if cached)..."
    . "$ROOT_DIR/scripts/lib.sh"
    prefetch_image portainer/agent:latest || true
    
    # 导入镜像到集群（避免镜像拉取失败）
    echo "[PORTAINER] Importing portainer/agent:latest to $provider cluster..."
    if [ "$provider" = "k3d" ]; then
      # k3d: 同时导入 CoreDNS 和 pause 镜像
      prefetch_image rancher/mirrored-pause:3.6 || true
      prefetch_image rancher/mirrored-coredns-coredns:1.12.0 || true
      k3d image import portainer/agent:latest rancher/mirrored-pause:3.6 rancher/mirrored-coredns-coredns:1.12.0 -c "$name" 2>/dev/null || true
    else
      # kind: 使用 preload_image_to_cluster 导入
      preload_image_to_cluster kind "$name" "portainer/agent:latest" || true
    fi
  else
    echo "[DRY-RUN][PORTAINER] 跳过镜像预拉取和导入"
  fi

  # 等待 CoreDNS 就绪（如果是 k3d，增加超时时间）
  if [ "$provider" = "k3d" ]; then
    if [ "${DRY_RUN:-}" != "1" ]; then
      echo "[PORTAINER] Waiting for CoreDNS to be ready (max 180s)..."
      kubectl --context "$ctx" wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=180s || {
        echo "[WARN] CoreDNS not ready within timeout, but continuing..."
      }
    else
      echo "[DRY-RUN][PORTAINER] 跳过等待 CoreDNS"
    fi
  fi

  # 如果 Edge Agent 已在 Running，则跳过注册
  if kubectl --context "$ctx" -n portainer-edge get pod -l app=portainer-edge-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q '^Running$'; then
    echo "[EDGE] agent already Running, skip registration"
  else
    # 注册 Edge Agent，允许失败（ArgoCD 会自动部署）
    "$ROOT_DIR"/scripts/register_edge_agent.sh "$name" "$provider" || echo "[WARN] Edge Agent registration failed, will be deployed by ArgoCD"
  fi
fi

# 注册到 ArgoCD（基于 reg_argocd 参数）
if [ "$reg_argocd" = 1 ]; then
  echo "[INFO] Registering cluster to ArgoCD..."
  if [ "${DRY_RUN:-}" != "1" ]; then
    if kubectl --context k3d-devops -n argocd get secret "cluster-${name}" >/dev/null 2>&1; then
      echo "[ARGOCD] secret cluster-${name} exists, skip register"
    else
      "$ROOT_DIR"/scripts/argocd_register.sh register "$name" "$provider" || echo "[WARNING] Failed to register to ArgoCD"
    fi
  else
    echo "[DRY-RUN][ARGOCD] 跳过集群注册"
  fi

  # 同步 ApplicationSet（自动为新环境部署 whoami）
  echo "[INFO] Syncing ApplicationSet for whoami..."
  # 轻量化：同步 ApplicationSet 影响 devops，一次即可；这里若 devops 就绪则同步
  if [ "${DRY_RUN:-}" != "1" ]; then
    if kubectl --context k3d-devops get ns argocd >/dev/null 2>&1; then
      "$ROOT_DIR"/scripts/sync_applicationset.sh || echo "[WARNING] Failed to sync ApplicationSet"
    else
      echo "[ARGOCD] devops not ready, skip appset sync"
    fi
  else
    echo "[DRY-RUN][ARGOCD] 跳过 ApplicationSet 同步"
  fi
else
  echo "[INFO] Skipping ArgoCD registration (--no-register-argocd specified)"
fi

# 保存集群配置到数据库
if db_is_available 2>/dev/null; then
  echo "[INFO] Saving cluster configuration to database..."
  # 从 CSV 或配置中获取 http_port 和 https_port
  http_port=$(awk -F, -v n="$name" '$0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print $7; exit}' "$ROOT_DIR/config/environments.csv" 2>/dev/null | trim || echo "")
  https_port=$(awk -F, -v n="$name" '$0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print $8; exit}' "$ROOT_DIR/config/environments.csv" 2>/dev/null | trim || echo "")
  subnet=$(subnet_for "$name" 2>/dev/null || echo "")
  
  # 使用默认值如果未找到
  http_port=${http_port:-18080}
  https_port=${https_port:-18443}
  
  if db_insert_cluster "$name" "$provider" "${subnet:-}" "$node_port" "$pf_port" "$http_port" "$https_port"; then
    echo "[INFO] ✓ Cluster configuration saved to database"
    
    # 创建 Git 分支（含 whoami manifests）
    echo "[INFO] Creating Git branch for $name..."
    if [ -f "$ROOT_DIR/scripts/create_git_branch.sh" ]; then
      if "$ROOT_DIR/scripts/create_git_branch.sh" "$name" 2>&1 | sed 's/^/  /'; then
        echo "[INFO] ✓ Git branch created successfully"
      else
        echo "[WARN] Git branch creation failed"
        echo "[WARN] You can manually create it later with:"
        echo "       scripts/create_git_branch.sh $name"
      fi
    else
      echo "[WARN] create_git_branch.sh not found, skipping Git branch creation"
    fi
  else
    echo "[WARN] Failed to save cluster configuration to database"
  fi
else
  echo "[INFO] Database not available, skipping configuration save and Git branch creation"
fi

echo "[SUCCESS] Cluster $name created successfully"
