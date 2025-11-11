#!/usr/bin/env bash
# 部署 PostgreSQL 到 devops 集群（极简版）
# 用于开发测试场景，直接使用 kubectl apply

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo "  部署 PostgreSQL 到 devops 集群"
echo "=========================================="
echo ""

# 加载密码配置
if [ -f "$ROOT_DIR/config/secrets.env" ]; then
  source "$ROOT_DIR/config/secrets.env"
fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-kindler123}"

echo "[STEP 1/5] 创建 namespace: paas"
kubectl --context k3d-devops create namespace paas --dry-run=client -o yaml | \
  kubectl --context k3d-devops apply -f -

echo ""
echo "[STEP 2/5] 创建 Secret: postgresql-secret"
kubectl --context k3d-devops create secret generic postgresql-secret \
  --namespace=paas \
  --from-literal=username=kindler \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --from-literal=database=kindler \
  --dry-run=client -o yaml | kubectl --context k3d-devops apply -f -

echo ""
echo "[STEP 3/5] 部署 PostgreSQL StatefulSet"
cat <<EOF | kubectl --context k3d-devops apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: paas
  labels:
    app: postgresql
spec:
  ports:
  - port: 5432
    name: postgres
  clusterIP: None
  selector:
    app: postgresql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: paas
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
      - name: postgresql
        image: postgres:16-alpine
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgresql-secret
              key: username
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-secret
              key: password
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: postgresql-secret
              key: database
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/postgresql/data
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U kindler
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U kindler
          initialDelaySeconds: 5
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: postgresql-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: local-path
      resources:
        requests:
          storage: 2Gi
EOF

echo ""
echo "[STEP 4/5] 等待 PostgreSQL 就绪（最多 120 秒）..."
kubectl --context k3d-devops wait --for=condition=ready pod \
  -l app=postgresql -n paas --timeout=120s || {
    echo "[ERROR] PostgreSQL 未能在 120 秒内就绪"
    echo "[DEBUG] Pod 状态："
    kubectl --context k3d-devops get pods -n paas
    echo "[DEBUG] Pod 详细信息："
    kubectl --context k3d-devops describe pod -l app=postgresql -n paas | tail -30
    exit 1
  }

echo ""
echo "[STEP 5/5] 测试 PostgreSQL 连接"
kubectl --context k3d-devops exec -i postgresql-0 -n paas -- \
  psql -U kindler -d kindler -c 'SELECT version();' | head -3

echo ""
echo "=========================================="
echo "✅ PostgreSQL 部署完成！"
echo "=========================================="
echo ""
echo "连接信息："
echo "  Pod:      postgresql-0"
echo "  Namespace: paas"
echo "  用户:     kindler"
echo "  数据库:   kindler"
echo "  密码:     $POSTGRES_PASSWORD"
echo ""
echo "测试连接："
echo "  kubectl --context k3d-devops exec -it postgresql-0 -n paas -- \\"
echo "    psql -U kindler -d kindler"
echo ""


