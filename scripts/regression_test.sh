#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

LOG_DIR="$PROJECT_ROOT/data/logs/regression"
mkdir -p "$LOG_DIR"

ROUNDS=${1:-3}
CURRENT_ROUND=0
TOTAL_FAILURES=0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

# 验证 Portainer 状态
verify_portainer() {
    log "验证 Portainer 状态..."
    
    if ! docker ps | grep -q portainer-ce; then
        error "Portainer 容器未运行"
        return 1
    fi
    
    local http_status=$(curl -s -o /dev/null -w "%{http_code}" "http://portainer.devops.192.168.51.30.sslip.io" 2>&1 || echo "000")
    if [[ "$http_status" != "301" && "$http_status" != "200" ]]; then
        error "Portainer HTTP 访问失败: $http_status"
        return 1
    fi
    
    log "✅ Portainer 状态正常"
    return 0
}

# 验证 ArgoCD 状态
verify_argocd() {
    log "验证 ArgoCD 状态..."
    
    # 等待所有 ArgoCD Pods Running（最多5分钟）
    log "等待 ArgoCD Pods 启动..."
    for i in {1..30}; do
        local not_running=$(kubectl --context k3d-devops get pods -n argocd --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
        if [ "$not_running" -eq 0 ]; then
            break
        fi
        log "  等待 ArgoCD Pods... ($i/30, $not_running pods 未就绪)"
        sleep 10
    done
    
    local argocd_pods=$(kubectl --context k3d-devops get pods -n argocd --no-headers 2>/dev/null | wc -l)
    if [ "$argocd_pods" -lt 5 ]; then
        error "ArgoCD Pods 数量不足: $argocd_pods"
        return 1
    fi
    
    local not_running=$(kubectl --context k3d-devops get pods -n argocd --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
    if [ "$not_running" -gt 0 ]; then
        error "ArgoCD 存在非 Running 状态的 Pods: $not_running"
        kubectl --context k3d-devops get pods -n argocd
        return 1
    fi
    
    log "✅ ArgoCD 状态正常"
    return 0
}

# 验证集群注册
verify_clusters() {
    log "验证集群注册状态..."
    
    local registered_count=0
    local failed_envs=""
    
    # 读取 environments.csv（跳过 devops 和注释）
    while IFS=, read -r env provider rest; do
        env=$(echo "$env" | tr -d ' ')
        provider=$(echo "$provider" | tr -d ' ')
        
        # 跳过空行和注释
        [[ -z "$env" || "$env" == "#"* ]] && continue
        # 跳过 devops
        [[ "$env" == "devops" ]] && continue
        
        local cluster_name="cluster-${env}"
        
        # 检查 ArgoCD 注册
        if kubectl --context k3d-devops get secret "$cluster_name" -n argocd &>/dev/null; then
            ((registered_count++))
            log "  ✅ $env ($provider) 已注册到 ArgoCD"
        else
            error "  ❌ $env ($provider) 未注册到 ArgoCD"
            failed_envs="$failed_envs $env"
            continue
        fi
        
        # 检查集群可访问
        local context_name
        if [[ "$provider" == "k3d" ]]; then
            context_name="k3d-${env}"
        else
            context_name="kind-${env}"
        fi
        
        if ! kubectl --context "$context_name" get nodes &>/dev/null; then
            error "  ❌ $env 集群不可访问"
            failed_envs="$failed_envs $env"
        fi
    done < <(tail -n +2 config/environments.csv)
    
    if [ -n "$failed_envs" ]; then
        error "以下集群验证失败:$failed_envs"
        return 1
    fi
    
    log "✅ 所有集群注册正常 ($registered_count 个)"
    return 0
}

# 部署 Traefik 到集群
deploy_traefik_to_cluster() {
    local env=$1
    local provider=$2
    local context_name
    
    if [[ "$provider" == "k3d" ]]; then
        context_name="k3d-${env}"
    else
        context_name="kind-${env}"
    fi
    
    log "  部署 Traefik 到 $env..."
    
    kubectl --context "$context_name" apply -f - <<'YAML' >/dev/null 2>&1
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik-ingress-controller
rules:
  - apiGroups: [""]
    resources: ["services", "secrets", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses", "ingressclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses/status"]
    verbs: ["update"]
  - apiGroups: ["traefik.io", "traefik.containo.us"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik-ingress-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-ingress-controller
subjects:
- kind: ServiceAccount
  name: traefik-ingress-controller
  namespace: kube-system
---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: kube-system
spec:
  type: NodePort
  selector:
    app: traefik
  ports:
    - name: web
      protocol: TCP
      port: 80
      targetPort: 8000
      nodePort: 30080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: kube-system
  labels:
    app: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik-ingress-controller
      containers:
      - name: traefik
        image: traefik:v2.10
        imagePullPolicy: IfNotPresent
        args:
          - --api.insecure=true
          - --providers.kubernetesingress=true
          - --entrypoints.web.address=:8000
          - --log.level=INFO
        ports:
          - name: web
            containerPort: 8000
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: traefik.io/ingress-controller
YAML
    
    return 0
}

# 验证 whoami 服务
verify_whoami_services() {
    log "验证 whoami 服务..."
    
    # 首先部署 Traefik 和配置路由
    log "部署 Traefik 到所有集群..."
    while IFS=, read -r env provider rest; do
        env=$(echo "$env" | tr -d ' ')
        provider=$(echo "$provider" | tr -d ' ')
        
        [[ -z "$env" || "$env" == "#"* || "$env" == "devops" ]] && continue
        
        deploy_traefik_to_cluster "$env" "$provider"
    done < <(tail -n +2 config/environments.csv | head -6)
    
    log "配置 HAProxy 路由..."
    while IFS=, read -r env provider rest; do
        env=$(echo "$env" | tr -d ' ')
        
        [[ -z "$env" || "$env" == "#"* || "$env" == "devops" ]] && continue
        
        ./scripts/haproxy_route.sh add "$env" >/dev/null 2>&1
    done < <(tail -n +2 config/environments.csv | head -6)
    
    # 等待 Traefik 和 whoami pods 启动
    log "等待服务就绪..."
    sleep 30
    
    local total=0
    local success=0
    local failed_services=""
    
    while IFS=, read -r env provider rest; do
        env=$(echo "$env" | tr -d ' ')
        provider=$(echo "$provider" | tr -d ' ')
        
        [[ -z "$env" || "$env" == "#"* || "$env" == "devops" ]] && continue
        
        ((total++))
        local url="http://whoami.${provider}.${env}.192.168.51.30.sslip.io"
        
        # 等待服务就绪（最多30秒）
        local ready=false
        for i in {1..6}; do
            local status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>&1 || echo "000")
            if [ "$status" = "200" ]; then
                ready=true
                break
            fi
            sleep 5
        done
        
        if $ready; then
            ((success++))
            log "  ✅ $env: $url"
        else
            error "  ❌ $env: $url (status: $status)"
            failed_services="$failed_services $env"
        fi
    done < <(tail -n +2 config/environments.csv | head -6)
    
    if [ "$success" -lt "$total" ]; then
        error "whoami 服务验证失败: $success/$total"
        error "失败的服务:$failed_services"
        return 1
    fi
    
    log "✅ 所有 whoami 服务正常 ($success/$total)"
    return 0
}

# 执行单轮测试
run_single_round() {
    local round=$1
    local round_log="$LOG_DIR/round_${round}_$(date +%Y%m%d_%H%M%S).log"
    
    log "=========================================="
    log "开始第 $round 轮回归测试"
    log "=========================================="
    
    {
        # 步骤 1: 清理
        log "步骤 1/4: 清理环境..."
        if ! ./scripts/clean.sh --all; then
            error "清理失败"
            return 1
        fi
        sleep 10
        
        # 步骤 2: Bootstrap
        log "步骤 2/4: Bootstrap 基础环境..."
        if ! ./scripts/bootstrap.sh; then
            error "Bootstrap 失败"
            return 1
        fi
        
        # 等待 ArgoCD 完全就绪
        sleep 30
        
        # 步骤 3: 创建所有业务集群
        log "步骤 3/4: 创建所有业务集群..."
        
        while IFS=, read -r env provider node_port pf_port register_portainer haproxy_route http_port https_port cluster_subnet; do
            env=$(echo "$env" | tr -d ' ')
            provider=$(echo "$provider" | tr -d ' ')
            
            [[ -z "$env" || "$env" == "#"* || "$env" == "devops" ]] && continue
            
            log "  创建集群: $env ($provider)..."
            if ! ./scripts/create_env.sh -n "$env" -p "$provider"; then
                error "创建集群 $env 失败"
                return 1
            fi
        done < <(tail -n +2 config/environments.csv | head -6)
        
        sleep 30
        
        # 步骤 4: 验证
        log "步骤 4/4: 验证所有组件..."
        
        local validation_failed=false
        
        if ! verify_portainer; then
            validation_failed=true
        fi
        
        if ! verify_argocd; then
            validation_failed=true
        fi
        
        if ! verify_clusters; then
            validation_failed=true
        fi
        
        if ! verify_whoami_services; then
            validation_failed=true
        fi
        
        if $validation_failed; then
            error "第 $round 轮验证失败"
            return 1
        fi
        
        log "=========================================="
        log "✅ 第 $round 轮回归测试通过"
        log "=========================================="
        return 0
        
    } 2>&1 | tee -a "$round_log"
    
    return ${PIPESTATUS[0]}
}

# 主流程
main() {
    log "=========================================="
    log "开始回归测试（共 $ROUNDS 轮）"
    log "=========================================="
    
    for ((round=1; round<=ROUNDS; round++)); do
        CURRENT_ROUND=$round
        
        if run_single_round $round; then
            log "第 $round 轮测试通过 ✅"
        else
            error "第 $round 轮测试失败 ❌"
            ((TOTAL_FAILURES++))
        fi
        
        if [ $round -lt $ROUNDS ]; then
            log "等待 30 秒后开始下一轮..."
            sleep 30
        fi
    done
    
    log "=========================================="
    log "回归测试完成"
    log "=========================================="
    log "总轮数: $ROUNDS"
    log "成功: $((ROUNDS - TOTAL_FAILURES))"
    log "失败: $TOTAL_FAILURES"
    
    if [ $TOTAL_FAILURES -eq 0 ]; then
        log "✅ 所有测试通过！"
        return 0
    else
        error "❌ 存在失败的测试"
        return 1
    fi
}

main "$@"
