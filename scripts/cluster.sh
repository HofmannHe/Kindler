#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<EOF
Usage: $0 <create|delete|import|status> <env> [args]

env: dev|uat|prod

Subcommands:
  create <env>            Create cluster for env (respect provider & host port mapping)
  delete <env>            Delete cluster for env
  import <env> <image>    Import local image into cluster
  status <env>            Show nodes for cluster context

Environment:
  DRY_RUN=1  Print commands instead of executing
EOF
}

run() { if [ "${DRY_RUN:-}" = "1" ]; then echo "+ $*"; else eval "$*"; fi }


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
  for i in $(seq 1 60); do
    if docker inspect "$cname" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if docker inspect "$cname" >/dev/null 2>&1; then
    run "docker update --cpus ${cpus} --memory ${mem} --memory-swap ${mem} ${cname} >/dev/null 2>&1 || true"
  fi
}
create_k3d() {
  local name="$1" http_port="$2" https_port="$3"
  need_cmd k3d || return 0
  local img_arg=""
  if [ -n "${K3D_IMAGE:-}" ]; then img_arg="--image ${K3D_IMAGE}"; fi

  # 使用共享网络以支持 ArgoCD 跨集群连接
  local network_arg="--network k3d-shared"

  # k3d使用默认API端口配置，创建后修正kubeconfig中的0.0.0.0地址
  run "k3d cluster create ${name} ${img_arg} ${network_arg} --servers 1 --agents 0 --port ${http_port}:80@loadbalancer --port ${https_port}:443@loadbalancer"
  limit_node_resources k3d "$name"

  # 修正kubeconfig中的0.0.0.0地址为127.0.0.1
  local cluster_name="k3d-${name}"
  local actual_port
  for i in $(seq 1 10); do
    actual_port=$(docker port "k3d-${name}-serverlb" 6443/tcp 2>/dev/null | grep "0.0.0.0" | cut -d: -f2 || true)
    if [ -n "$actual_port" ]; then
      log INFO "Fixing API server address from 0.0.0.0:$actual_port to 127.0.0.1:$actual_port"
      kubectl config set-cluster "$cluster_name" --server="https://127.0.0.1:$actual_port" >/dev/null 2>&1 || true
      break
    fi
    sleep 1
  done
}

delete_k3d() { local name="$1"; need_cmd k3d || return 0; run "k3d cluster delete ${name}"; }

import_k3d() { local name="$1" image="$2"; need_cmd k3d || return 0; run "k3d image import ${image} -c ${name}"; }

create_kind() {
  local name="$1" http_port="$2" https_port="$3"
  need_cmd kind || return 0
  local cfg
  cfg="$(mktemp)"
  if [ -n "${http_port:-}" ] && [ -n "${https_port:-}" ]; then
    cat >"$cfg" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
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
    cat >"$cfg" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
nodes:
- role: control-plane
YAML
  fi
  local img_arg=""
  if [ -n "${KIND_NODE_IMAGE:-}" ]; then img_arg="--image ${KIND_NODE_IMAGE}"; fi
  run "kind create cluster --name ${name} --config ${cfg} ${img_arg}"
  limit_node_resources kind "$name"
}

delete_kind() { local name="$1"; need_cmd kind || return 0; run "kind delete cluster --name ${name}"; }

import_kind() { local name="$1" image="$2"; need_cmd kind || return 0; run "kind load docker-image ${image} --name ${name}"; }

main() {
  load_env
  local cmd="${1:-}" env="${2:-}" arg3="${3:-}"
  if [ -z "$cmd" ] || [ -z "$env" ]; then usage; exit 1; fi

  local provider name ports http_port https_port
  provider="$(provider_for "$env")"
  name="$(ctx_name "$env")"
  # read ports with space separator regardless of global IFS
  local _ports
  _ports="$(ports_for "$env")"
  IFS=' ' read -r http_port https_port <<< "${_ports}"
  IFS=$'\n\t'

  case "$cmd" in
    create)
      if [ "$provider" = "k3d" ]; then create_k3d "$name" "$http_port" "$https_port"; else create_kind "$name" "$http_port" "$https_port"; fi
      ;;
    delete)
      if [ "$provider" = "k3d" ]; then delete_k3d "$name"; else delete_kind "$name"; fi
      ;;
    import)
      [ -n "$arg3" ] || { log ERROR "image required"; exit 1; }
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
    *) usage; exit 1 ;;
  esac
}

main "$@"
