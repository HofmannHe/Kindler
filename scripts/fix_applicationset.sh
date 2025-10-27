#!/usr/bin/env bash
# 修复 ApplicationSet 配置，使其与 environments.csv 和当前集群状态一致
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/config/clusters.env" 2>/dev/null || true

echo "=========================================="
echo "  修复 ApplicationSet 配置"
echo "=========================================="

# 1. 读取当前所有业务集群（从数据库）
echo "[1/3] 读取集群列表（从数据库）..."
clusters=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
  psql -U kindler -d kindler -t -c "SELECT name FROM clusters WHERE name != 'devops';" 2>/dev/null | \
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in database"
  exit 0
fi

echo "  Found clusters:"
for cluster in $clusters; do
  echo "    - $cluster"
done

# 2. 生成 ApplicationSet elements
echo "[2/3] Generating ApplicationSet elements..."

cat > /tmp/applicationset_elements.json << 'EOF'
[
EOF

first=true
for cluster in $clusters; do
  if [ "$first" = "false" ]; then
    echo "," >> /tmp/applicationset_elements.json
  fi
  first=false
  
  cat >> /tmp/applicationset_elements.json <<EOF
  {
    "branch": "$cluster",
    "clusterName": "$cluster",
    "env": "$cluster",
    "hostEnv": "$cluster",
    "ingressClass": "traefik"
  }
EOF
done

cat >> /tmp/applicationset_elements.json << 'EOF'
]
EOF

echo "  ✓ Generated elements for $(echo "$clusters" | wc -w) clusters"

# 3. 应用到 ApplicationSet
echo "[3/3] Updating ApplicationSet..."

kubectl --context k3d-devops -n argocd patch applicationset whoami --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/generators/0/list/elements\",
    \"value\": $(cat /tmp/applicationset_elements.json)
  }
]" && echo "  ✓ ApplicationSet updated successfully" || {
  echo "  ✗ Failed to update ApplicationSet"
  exit 1
}

# 清理
rm -f /tmp/applicationset_elements.json

echo "=========================================="
echo "✓ ApplicationSet 已修复"
echo "=========================================="

# 显示当前配置
echo ""
echo "当前 ApplicationSet elements:"
kubectl --context k3d-devops -n argocd get applicationset whoami -o jsonpath='{range .spec.generators[0].list.elements[*]}{.clusterName}{"\n"}{end}' | sed 's/^/  - /'

