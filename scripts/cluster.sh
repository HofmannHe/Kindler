#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Unified dispatcher for cluster lifecycle commands (create/delete/import/status/start/stop/list).
# Usage: scripts/cluster.sh <create|delete|import|status|start|stop|list> <env> [args]
# Category: lifecycle
# Status: stable
# See also: scripts/create_env.sh, scripts/delete_env.sh, scripts/clean.sh

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=lib/lib.sh
. "$ROOT_DIR/scripts/lib/lib.sh"
# shellcheck source=lib/lib_sqlite.sh
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

usage() {
  cat << EOF
Usage: $0 <create|delete|import|status|start|stop|list> <env> [args]

env: dev|uat|prod

Subcommands:
  create <env>            Create cluster for env (respect provider & host port mapping)
  delete <env>            Delete cluster for env
  import <env> <image>    Import local image into cluster
  status <env>            Show nodes for cluster context
  start <env>             Start an existing cluster
  stop <env>              Stop an existing cluster (preserve config)
  list                    List configured environments (DB first, CSV fallback)

Environment:
  DRY_RUN=1  Print commands instead of executing
EOF
}

run() { if [ "${DRY_RUN:-}" = "1" ]; then echo "+ $*"; else eval "$*"; fi; }

# Apply container resource limits to the created node container
limit_node_resources() {
  local provider="$1" name="$2"
  # defaults: 4 vcpu + 8g mem (can be overridden by env)
  local cpus mem
  cpus="${NODE_CPUS:-${DEFAULT_NODE_CPUS:-4}}"
  mem="${NODE_MEMORY:-${DEFAULT_NODE_MEMORY:-8g}}"
  local cname
  if [ "$provider" = "k3d" ]; then
    cname="k3d-${name}-server-0"
  else
    cname="${name}-control-plane"
  fi
  # wait until container exists
  for _ in $(seq 1 60); do
    if docker inspect "$cname" > /dev/null 2>&1; then break; fi
    sleep 1
  done
  if docker inspect "$cname" > /dev/null 2>&1; then
    run "docker update --cpus ${cpus} --memory ${mem} --memory-swap ${mem} ${cname} >/dev/null 2>&1 || true"
  fi
}
create_k3d() {
  local name="$1" http_port="$2" https_port="$3"
  need_cmd k3d || return 0
  local img_arg=""
  if [ -n "${K3D_IMAGE:-}" ]; then img_arg="--image ${K3D_IMAGE}"; fi

  # 读取集群子网配置（从 CSV）
  local subnet network_name network_arg
  subnet="$(subnet_for "$name")"

  if [ -n "$subnet" ]; then
    # 使用独立子网：创建专用网络
    network_name="k3d-${name}"
    log INFO "Creating dedicated network for k3d cluster: $network_name (subnet: $subnet)"

    # 创建独立网络（幂等）
    if ! docker network inspect "$network_name" > /dev/null 2>&1; then
      # 从子网计算网关地址（使用 .0.1）
      local gateway
      gateway=$(echo "$subnet" | sed -E 's|([0-9]+\.[0-9]+)\.0\.0/[0-9]+|\1.0.1|')
      run "docker network create \"$network_name\" --subnet \"$subnet\" --gateway \"$gateway\" --opt com.docker.network.bridge.name=\"br-k3d-${name}\""
      log INFO "Network $network_name created with subnet $subnet (gateway: $gateway)"
    else
      log INFO "Network $network_name already exists"
    fi
    network_arg="--network $network_name"
  else
    # 未指定子网：使用共享网络 k3d-shared（用于 devops 集群）
    log INFO "No subnet specified for cluster $name, using shared network k3d-shared"
    network_arg="--network k3d-shared"
  fi

  # devops 集群禁用 Traefik（管理集群不需要 Ingress Controller，避免端口冲突）
  local k3s_args=""
  if [ "$name" = "devops" ]; then
    k3s_args='--k3s-arg "--disable=traefik@server:0"'
    log INFO "Disabling Traefik for devops cluster (management cluster uses NodePort directly)"
  fi

  # k3d使用默认API端口配置，创建后修正kubeconfig中的0.0.0.0地址
  run "k3d cluster create ${name} ${img_arg} ${network_arg} ${k3s_args} --servers 1 --agents 0 --port ${http_port}:80@loadbalancer --port ${https_port}:443@loadbalancer"
  limit_node_resources k3d "$name"

  # 修正kubeconfig中的0.0.0.0地址为127.0.0.1
  local cluster_name="k3d-${name}"
  local actual_port
  for _ in $(seq 1 10); do
    actual_port=$(docker port "k3d-${name}-serverlb" 6443/tcp 2> /dev/null | grep "0.0.0.0" | cut -d: -f2 || true)
    if [ -n "$actual_port" ]; then
      log INFO "Fixing API server address from 0.0.0.0:$actual_port to 127.0.0.1:$actual_port"
      kubectl config set-cluster "$cluster_name" --server="https://127.0.0.1:$actual_port" > /dev/null 2>&1 || true
      # Avoid certificate SAN mismatch when using 127.0.0.1
      kubectl config set-cluster "$cluster_name" --insecure-skip-tls-verify=true > /dev/null 2>&1 || true
      break
    fi
    sleep 1
  done
}

delete_k3d() {
  local name="$1"
  need_cmd k3d || return 0
  run "k3d cluster delete ${name}"
}

import_k3d() {
  local name="$1" image="$2"
  need_cmd k3d || return 0
  run "k3d image import ${image} -c ${name}"
}

create_kind() {
  local name="$1" http_port="$2" https_port="$3"
  need_cmd kind || return 0
  local cfg
  cfg="$(mktemp)"
  if [ -n "${http_port:-}" ] && [ -n "${https_port:-}" ]; then
    cat > "$cfg" << YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
networking:
  # 关键：API 绑定 0.0.0.0，便于 devops(k3d) 中的 ArgoCD 通过 host.k3d.internal:<port> 访问
  apiServerAddress: "0.0.0.0"
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: ${http_port}
    protocol: TCP
  - containerPort: 443
    hostPort: ${https_port}
    protocol: TCP
YAML
  else
    cat > "$cfg" << YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
networking:
  # 关键：API 绑定 0.0.0.0，便于 devops(k3d) 中的 ArgoCD 通过 host.k3d.internal:<port> 访问
  apiServerAddress: "0.0.0.0"
nodes:
- role: control-plane
YAML
  fi
  local img_arg=""
  if [ -n "${KIND_NODE_IMAGE:-}" ]; then img_arg="--image ${KIND_NODE_IMAGE}"; fi
  run "kind create cluster --name ${name} --config ${cfg} ${img_arg}"
  limit_node_resources kind "$name"

  # 修正 kubeconfig 中的 0.0.0.0 地址为 127.0.0.1（主机访问更稳定）
  local host_port
  host_port=$(docker port "${name}-control-plane" 6443/tcp 2> /dev/null | awk -F: '{print $NF}' | tail -1 || true)
  if [ -n "$host_port" ]; then
    log INFO "Fixing kind kubeconfig server from 0.0.0.0:$host_port to 127.0.0.1:$host_port"
    kubectl config set-cluster "kind-${name}" --server="https://127.0.0.1:${host_port}" > /dev/null 2>&1 || true
    # Avoid certificate SAN mismatch (0.0.0.0 vs 127.0.0.1)
    kubectl config set-cluster "kind-${name}" --insecure-skip-tls-verify=true > /dev/null 2>&1 || true
  fi
}

delete_kind() {
  local name="$1"
  need_cmd kind || return 0
  run "kind delete cluster --name ${name}"
}

import_kind() {
  local name="$1" image="$2"
  need_cmd kind || return 0
  run "kind load docker-image ${image} --name ${name}"
}

main() {
  load_env
  local cmd="${1:-}" env="${2:-}" arg3="${3:-}"
  if [ -z "$cmd" ]; then
    usage
    exit 1
  fi

  local provider name http_port https_port
  if [ -n "${env:-}" ]; then
    provider="$(provider_for "$env")"
    name="$(ctx_name "$env")"
    # read ports with space separator regardless of global IFS
    local _ports
    _ports="$(ports_for "$env")"
    IFS=' ' read -r http_port https_port <<< "${_ports}"
    IFS=$'\n\t'
  fi

  case "$cmd" in
    create)
      if [ "$provider" = "k3d" ]; then create_k3d "$name" "$http_port" "$https_port"; else create_kind "$name" "$http_port" "$https_port"; fi
      ;;
    delete)
      if [ "$provider" = "k3d" ]; then delete_k3d "$name"; else delete_kind "$name"; fi
      ;;
    import)
      [ -n "$arg3" ] || {
        log ERROR "image required"
        exit 1
      }
      if [ "$provider" = "k3d" ]; then import_k3d "$name" "$arg3"; else import_kind "$name" "$arg3"; fi
      ;;
    status)
      need_cmd kubectl || exit 0
      local ctx
      if [ "$provider" = "k3d" ]; then
        ctx="k3d-${name}"
      else
        ctx="kind-${name}"
      fi
      run "kubectl config use-context ${ctx} >/dev/null 2>&1 || true"
      run "kubectl --context ${ctx} get nodes"
      ;;
    start)
      [ -n "${env:-}" ] || {
        usage
        exit 1
      }
      if [ "$provider" = "k3d" ]; then
        run "k3d cluster start ${name}"
      else
        # kind: start control-plane container(s)
        local ctn
        for ctn in $(docker ps -aq --filter "name=${name}-control-plane"); do
          run "docker start ${ctn} >/dev/null"
        done
      fi
      ;;
    stop)
      [ -n "${env:-}" ] || {
        usage
        exit 1
      }
      if [ "$provider" = "k3d" ]; then
        run "k3d cluster stop ${name}"
      else
        local ctn
        for ctn in $(docker ps -q --filter "name=${name}-control-plane"); do
          run "docker stop ${ctn} >/dev/null || true"
        done
      fi
      ;;
    list)
      # Prefer SQLite database
      if db_is_available > /dev/null 2>&1; then
        echo "NAME            PROVIDER  SUBNET             NODE_PORT PF_PORT  HTTP_PORT  HTTPS_PORT"
        echo "-------------------------------------------------------------------------------------"
        db_list_clusters 2> /dev/null | while IFS='|' read -r n prov subnet node_port pf_port hp hs; do
          [ -z "$subnet" ] && subnet="N/A"
          printf "%-15s %-9s %-18s %-9s %-7s %-10s %-11s\n" "$n" "$prov" "$subnet" "$node_port" "$pf_port" "$hp" "$hs"
        done
      else
        # Fallback to CSV
        local csv="$ROOT_DIR/config/environments.csv"
        [ -f "$csv" ] || {
          echo "[ERROR] CSV not found: $csv" >&2
          exit 1
        }
        echo "NAME            PROVIDER  SUBNET             NODE_PORT PF_PORT  HTTP_PORT  HTTPS_PORT"
        echo "-------------------------------------------------------------------------------------"
        awk -F, '$0 !~ /^[[:space:]]*#/ && NF>0 && NR>1 {gsub(/^ +| +$/,"",$1);gsub(/^ +| +$/,"",$2);gsub(/^ +| +$/,"",$9);gsub(/^ +| +$/,"",$3);gsub(/^ +| +$/,"",$4);gsub(/^ +| +$/,"",$7);gsub(/^ +| +$/,"",$8); s=($9==""||$9=="N/A")?"N/A":$9; printf "%-15s %-9s %-18s %-9s %-7s %-10s %-11s\n", $1,$2,s,$3,$4,$7,$8}' "$csv"
      fi
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
