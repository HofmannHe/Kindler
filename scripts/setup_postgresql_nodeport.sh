#!/usr/bin/env bash
# 为PostgreSQL创建NodePort Service
# 使外部（HAProxy）能够通过NodePort访问PostgreSQL

set -Eeuo pipefail

echo "[PG-NODEPORT] Creating PostgreSQL NodePort Service..."

# 等待PostgreSQL Pod就绪
max_wait=120
elapsed=0
while [ $elapsed -lt $max_wait ]; do
  if kubectl --context k3d-devops -n paas get pod postgresql-0 >/dev/null 2>&1; then
    if kubectl --context k3d-devops -n paas wait pod/postgresql-0 --for=condition=ready --timeout=10s >/dev/null 2>&1; then
      echo "[PG-NODEPORT] PostgreSQL Pod is ready"
      break
    fi
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  echo "[PG-NODEPORT] Waiting for PostgreSQL Pod... (${elapsed}s/${max_wait}s)"
done

if [ $elapsed -ge $max_wait ]; then
  echo "[ERROR] PostgreSQL Pod not ready after ${max_wait}s"
  exit 1
fi

# 检查NodePort Service是否已存在
if kubectl --context k3d-devops -n paas get svc postgresql-nodeport >/dev/null 2>&1; then
  echo "[PG-NODEPORT] NodePort Service already exists"
  kubectl --context k3d-devops -n paas get svc postgresql-nodeport
  exit 0
fi

# 创建NodePort Service
cat <<EOF | kubectl --context k3d-devops -n paas apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgresql-nodeport
  namespace: paas
  labels:
    app: postgresql
spec:
  type: NodePort
  selector:
    app: postgresql
  ports:
  - port: 5432
    targetPort: 5432
    nodePort: 30432
    protocol: TCP
    name: postgresql
EOF

echo "[PG-NODEPORT] ✓ NodePort Service created"
kubectl --context k3d-devops -n paas get svc postgresql-nodeport

echo "[PG-NODEPORT] Done"


