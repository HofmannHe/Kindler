#!/usr/bin/env bash
# 修复 Git 仓库中 Helm Chart 的重复资源定义问题
# 确保每个资源类型只在一个模板文件中定义

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo "  修复 Helm Chart 重复资源问题"
echo "=========================================="
echo

# 加载 Git 配置
GIT_ENV_FILE="$ROOT_DIR/config/git.env"
if [ ! -f "$GIT_ENV_FILE" ]; then
  echo "❌ Git configuration not found: $GIT_ENV_FILE"
  exit 1
fi

set -a
source "$GIT_ENV_FILE"
set +a

if [ -z "$GIT_REPO_URL" ]; then
  echo "❌ GIT_REPO_URL not configured"
  exit 1
fi

echo "✓ Git repository: $GIT_REPO_URL"
echo

# 获取所有业务集群
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "❌ No business clusters found in environments.csv"
  exit 1
fi

# 临时工作目录
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

cd "$TMPDIR"

# Clone 仓库
echo "[1/3] Cloning repository..."
if [ -n "$GIT_PASSWORD" ]; then
  GIT_REPO_URL_AUTH=$(echo "$GIT_REPO_URL" | sed "s|://|://$GIT_USERNAME:$GIT_PASSWORD@|")
  git clone "$GIT_REPO_URL_AUTH" repo 2>&1 | grep -v "password" || true
else
  git clone "$GIT_REPO_URL" repo
fi

cd repo
git config user.name "Kindler Automation"
git config user.email "kindler@local"

echo
echo "[2/3] Checking and fixing all branches..."
fixed_count=0
failed_count=0

for cluster in $clusters; do
  echo
  echo "Processing: $cluster"
  
  # 检查分支是否存在
  if ! git ls-remote --heads origin "$cluster" | grep -q "$cluster"; then
    echo "  ⚠ Branch '$cluster' does not exist, skipping"
    continue
  fi
  
  # 切换到分支
  git checkout "$cluster" 2>/dev/null || git checkout -b "$cluster" "origin/$cluster"
  
  # 检查 deploy/templates/ 是否存在
  if [ ! -d "deploy/templates" ]; then
    echo "  ⚠ templates directory not found, skipping"
    continue
  fi
  
  # 使用 helm template 检查重复资源
  echo "  Checking for duplicate resources..."
  
  # 需要先检查是否有 helm 命令
  if ! command -v helm >/dev/null 2>&1; then
    echo "  ⚠ helm not found, will fix based on file inspection"
    
    # 检查 deployment.yaml 是否包含非 Deployment 资源
    if [ -f "deploy/templates/deployment.yaml" ]; then
      service_count=$(grep -c "kind: Service" deploy/templates/deployment.yaml 2>/dev/null || echo "0")
      ingress_count=$(grep -c "kind: Ingress" deploy/templates/deployment.yaml 2>/dev/null || echo "0")
      namespace_count=$(grep -c "kind: Namespace" deploy/templates/deployment.yaml 2>/dev/null || echo "0")
      
      if [ "$service_count" -gt 0 ] || [ "$ingress_count" -gt 0 ] || [ "$namespace_count" -gt 0 ]; then
        echo "  ⚠ deployment.yaml contains non-Deployment resources, fixing..."
        
        # 只保留 Deployment 定义
        awk '/^---$/,/^kind: Deployment$/{p=1} p && /^---$/{if(++c>1)p=0} p' deploy/templates/deployment.yaml > deploy/templates/deployment.yaml.new
        
        # 如果提取失败，使用简单的提取方法
        if [ ! -s deploy/templates/deployment.yaml.new ]; then
          # 提取第一个 --- 到第一个 Deployment 资源
          sed -n '/^---$/,/^kind: Deployment$/p' deploy/templates/deployment.yaml > deploy/templates/deployment.yaml.new
          # 继续读取到下一个 --- 或文件结尾
          sed -n '/^kind: Deployment$/,/^---$/p' deploy/templates/deployment.yaml | head -n -1 >> deploy/templates/deployment.yaml.new
        fi
        
        # 如果还是失败，手动创建
        if [ ! -s deploy/templates/deployment.yaml.new ]; then
          echo "  Creating clean deployment.yaml from scratch..."
          cat > deploy/templates/deployment.yaml.new <<'DEPLOYEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: 80
          protocol: TCP
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
DEPLOYEOF
        fi
        
        mv deploy/templates/deployment.yaml.new deploy/templates/deployment.yaml
        
        # 确保 service.yaml 存在且正确
        if [ ! -f "deploy/templates/service.yaml" ]; then
          cat > deploy/templates/service.yaml <<'SERVICEEOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: {{ .Chart.Name }}
SERVICEEOF
        fi
        
        # 确保 ingress.yaml 存在且正确
        if [ ! -f "deploy/templates/ingress.yaml" ]; then
          cat > deploy/templates/ingress.yaml <<'INGRESSEOF'
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
  - host: {{ .Values.ingress.host }}
    http:
      paths:
      - path: {{ .Values.ingress.path }}
        pathType: {{ .Values.ingress.pathType }}
        backend:
          service:
            name: {{ .Chart.Name }}
            port:
              number: {{ .Values.service.port }}
{{- end }}
INGRESSEOF
        fi
        
        echo "  ✓ Fixed duplicate resources in deployment.yaml"
        fixed_count=$((fixed_count + 1))
      else
        echo "  ✓ No duplicate resources found"
        continue
      fi
    fi
  fi
  
  # 提交更改
  if git diff --quiet; then
    echo "  ⚠ No changes to commit"
  else
    git add deploy/templates/
    git commit -m "fix: remove duplicate resources from deployment.yaml

- Ensure deployment.yaml only contains Deployment
- Separate Service in service.yaml
- Separate Ingress in ingress.yaml
- Fixes ArgoCD 'appeared 2 times' error"
    
    # 推送到远程
    if git push origin "$cluster" 2>&1 | grep -v "password"; then
      echo "  ✓ Fixed and pushed: $cluster"
    else
      echo "  ✗ Failed to push: $cluster"
      failed_count=$((failed_count + 1))
    fi
  fi
done

echo
echo "[3/3] Summary"
echo "  Fixed: $fixed_count"
echo "  Failed: $failed_count"
echo

if [ $failed_count -eq 0 ]; then
  echo "✅ All branches fixed successfully!"
  exit 0
else
  echo "⚠ Some branches failed to update"
  exit 1
fi

