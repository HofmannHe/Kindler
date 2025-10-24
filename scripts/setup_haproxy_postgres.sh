#!/usr/bin/env bash
# 自动配置HAProxy PostgreSQL TCP代理
# 在bootstrap时调用，确保WebUI能连接PostgreSQL

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"

echo "[HAPROXY-PG] Configuring PostgreSQL TCP proxy..."

# 检查配置是否已存在
if grep -q "frontend fe_postgres" "$CFG" 2>/dev/null; then
  echo "[HAPROXY-PG] PostgreSQL proxy already configured"
  exit 0
fi

# 获取devops节点IP
devops_ip=$(docker inspect k3d-devops-server-0 --format='{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "k3d-shared"}}{{$conf.IPAddress}}{{end}}{{end}}' 2>/dev/null || echo "")

if [ -z "$devops_ip" ]; then
  echo "[ERROR] Cannot find devops cluster IP in k3d-shared network"
  exit 1
fi

echo "[HAPROXY-PG] devops cluster IP: $devops_ip"

# 添加PostgreSQL代理配置
cat >> "$CFG" <<EOF

# PostgreSQL TCP proxy (for WebUI backend and external access)
# Auto-configured by scripts/setup_haproxy_postgres.sh
frontend fe_postgres
  bind *:5432
  mode tcp
  default_backend be_postgres

backend be_postgres
  mode tcp
  timeout server 600s
  timeout connect 10s
  # 连接到devops集群中的PostgreSQL NodePort Service
  # devops节点IP: $devops_ip (k3d-shared网络)
  # NodePort: 30432 (postgresql-nodeport Service)
  server postgres1 $devops_ip:30432 check inter 5s fall 3 rise 2
EOF

echo "[HAPROXY-PG] ✓ PostgreSQL proxy configuration added"

# 重启HAProxy以应用配置
if docker ps | grep -q haproxy-gw; then
  echo "[HAPROXY-PG] Restarting HAProxy..."
  docker restart haproxy-gw >/dev/null 2>&1
  sleep 3
  
  # 验证端口监听
  if docker exec haproxy-gw netstat -tlnp 2>/dev/null | grep -q ":5432"; then
    echo "[HAPROXY-PG] ✓ PostgreSQL proxy is listening on port 5432"
  else
    echo "[WARN] PostgreSQL proxy port 5432 not listening"
    docker logs haproxy-gw 2>&1 | tail -10
  fi
else
  echo "[HAPROXY-PG] HAProxy not running, will apply on next start"
fi

echo "[HAPROXY-PG] Done"


