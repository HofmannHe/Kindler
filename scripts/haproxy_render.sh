#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
CSV="$ROOT_DIR/config/environments.csv"

. "$ROOT_DIR/scripts/lib.sh"
load_env

usage() {
  cat >&2 <<USG
Usage: $0 [--dry-run]

说明：
- 仅渲染动态后端（BACKENDS），不改动 ACL 区域；根据 CSV (haproxy_route=true) 生成后端列表。
- 仅为“实际存在”的集群生成后端；跳过不存在或未就绪的集群，避免写入 127.0.0.1 或 Service 网段地址。
- 单次重载 HAProxy。
USG
}

dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

resolve_ip() {
  local env="$1" ip=""
  # kind: 优先取 kind 网络 IP；回退到第一个 IP（空格分隔）
  if ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${env}-control-plane" 2>/dev/null); then
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${env}-control-plane" 2>/dev/null | awk '{print $1}'); then
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  # k3d: 优先专用网络，其次 k3d-shared；回退第一个 IP
  if ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "k3d-'"$env"'"}}{{.IPAddress}}{{end}}' "k3d-${env}-server-0" 2>/dev/null); then
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  if ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "k3d-shared"}}{{.IPAddress}}{{end}}' "k3d-${env}-server-0" 2>/dev/null); then
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "k3d-${env}-server-0" 2>/dev/null | awk '{print $1}'); then
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  # 未能解析容器 IP 时返回空，由调用方决定是否跳过
  echo ""
}

# 判断目标集群容器是否存在（避免渲染不存在的后端）
cluster_container_exists() {
  local env="$1" provider="$2"
  if [ "$provider" = "kind" ]; then
    docker inspect "${env}-control-plane" >/dev/null 2>&1
  else
    docker inspect "k3d-${env}-server-0" >/dev/null 2>&1
  fi
}

# 确保 HAProxy 连接到对应网络（避免网络不可达）
ensure_haproxy_network() {
  local env="$1" provider="$2"
  local n=""
  if [ "$provider" = "kind" ]; then
    n="kind"
  else
    if docker network inspect "k3d-${env}" >/dev/null 2>&1; then
      n="k3d-${env}"
    else
      n="k3d-shared"
    fi
  fi
  if [ -n "$n" ]; then
    if ! docker inspect haproxy-gw 2>/dev/null | jq -e ".[0].NetworkSettings.Networks.\"$n\"" >/dev/null 2>&1; then
      docker network connect "$n" haproxy-gw >/dev/null 2>&1 || true
    fi
  fi
}

is_true() {
  case "$(echo "${1:-}" | tr 'A-Z' 'a-z')" in 1|y|yes|true|on) return 0;; *) return 1;; esac
}

render_backends() {
  [ -f "$CSV" ] || { echo "[render] CSV not found: $CSV" >&2; exit 1; }
  [ -f "$CFG" ] || { echo "[render] CFG not found: $CFG" >&2; exit 1; }
  tmp_be=$(mktemp)
  # Generate dynamic backends from CSV (skip devops)
  while IFS=, read -r env provider node_port pf_port reg_portainer haproxy_route http_port https_port _subnet; do
    [[ "$env" =~ ^[[:space:]]*# ]] && continue
    [ -n "$env" ] || continue
    [ "$env" = "devops" ] && continue
    if [ -n "${haproxy_route:-}" ] && ! is_true "$haproxy_route"; then
      continue
    fi
    # 仅为实际存在的集群渲染后端
    if ! cluster_container_exists "$env" "${provider:-k3d}"; then
      echo "[render] skip $env ($provider): cluster container not found"
      continue
    fi
    # 解析容器 IP（仅接受非空）
    ip=$(resolve_ip "$env")
    if [ -z "$ip" ]; then
      echo "[render] skip $env: cannot resolve container IP"
      continue
    fi
    # 额外防护：拒绝 10.0.0.0/8（常见 Service CIDR）
    if echo "$ip" | grep -qE '^10\.'; then
      echo "[render] skip $env: resolved to service-CIDR like IP ($ip)"
      continue
    fi
    # 确保 HAProxy 连接到对应网络
    ensure_haproxy_network "$env" "${provider:-k3d}"
    port="${node_port:-30080}"
    printf 'backend be_%s\n  server s1 %s:%s\n' "$env" "$ip" "$port" >> "$tmp_be"
  done < <(grep -v '^\s*$' "$CSV")

  tmp="$CFG.tmp"
  awk -v befile="$tmp_be" '
    BEGIN{inblk=0}
    {
      if ($0 ~ /# BEGIN DYNAMIC BACKENDS/) {
        print $0;                      # print BEGIN line
        system("cat " befile);        # inject backends (no extra indent)
        print "# END DYNAMIC BACKENDS";   # ensure END marker exists
        inblk=1;                       # skip until old END
        next
      }
      if (inblk) {
        if ($0 ~ /# END DYNAMIC BACKENDS/) { inblk=0; next } else { next }
      }
      print $0
    }
  ' "$CFG" > "$tmp"
  mv "$tmp" "$CFG"
  rm -f "$tmp_be"
}

main() {
  render_backends
  if [ "$dry" = 1 ]; then
    echo "[haproxy] dry-run backend render complete (no restart)."
  else
    docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" restart haproxy >/dev/null 2>&1 || \
      docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml" up -d haproxy >/dev/null
    echo "[haproxy] backends rendered and reloaded."
  fi
}

main "$@"
