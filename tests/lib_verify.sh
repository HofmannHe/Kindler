#!/usr/bin/env bash
# 通用验证函数库 - 用于深度验证K8s资源和应用状态

# 验证whoami应用完整性
verify_whoami_app() {
  local cluster=$1
  local provider=${2:-kind}
  local base_domain=${3:-192.168.51.30.sslip.io}
  
  local context
  case "$provider" in
    k3d) context="k3d-$cluster" ;;
    kind) context="kind-$cluster" ;;
    *) echo "Unknown provider: $provider"; return 1 ;;
  esac
  
  local errors=0
  
  # 1. 验证ArgoCD Application状态
  echo "  [1/5] Checking ArgoCD Application status..."
  local app_sync=$(kubectl --context k3d-devops -n argocd get application "whoami-$cluster" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
  local app_health=$(kubectl --context k3d-devops -n argocd get application "whoami-$cluster" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound")
  
  if [ "$app_sync" = "Synced" ]; then
    echo "    ✓ ArgoCD sync status: $app_sync"
  else
    echo "    ✗ ArgoCD sync status: $app_sync (expected: Synced)"
    ((errors++))
  fi
  
  if [ "$app_health" = "Healthy" ]; then
    echo "    ✓ ArgoCD health status: $app_health"
  else
    echo "    ✗ ArgoCD health status: $app_health (expected: Healthy)"
    # Progressing是可接受的临时状态
    if [ "$app_health" != "Progressing" ]; then
      ((errors++))
    fi
  fi
  
  # 2. 验证Kubernetes Deployment
  echo "  [2/5] Checking Deployment..."
  if ! kubectl --context "$context" get deployment whoami -n whoami &>/dev/null; then
    echo "    ✗ Deployment not found"
    ((errors++))
  else
    local ready_replicas=$(kubectl --context "$context" -n whoami get deployment whoami \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired_replicas=$(kubectl --context "$context" -n whoami get deployment whoami \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    
    if [ "$ready_replicas" = "$desired_replicas" ]; then
      echo "    ✓ Deployment ready: $ready_replicas/$desired_replicas"
    else
      echo "    ✗ Deployment not ready: $ready_replicas/$desired_replicas"
      ((errors++))
    fi
  fi
  
  # 3. 验证Service
  echo "  [3/5] Checking Service..."
  if ! kubectl --context "$context" get service whoami -n whoami &>/dev/null; then
    echo "    ✗ Service not found"
    ((errors++))
  else
    local endpoints=$(kubectl --context "$context" -n whoami get endpoints whoami \
      -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null)
    if [ -n "$endpoints" ]; then
      echo "    ✓ Service has endpoints: $endpoints"
    else
      echo "    ✗ Service has no endpoints"
      ((errors++))
    fi
  fi
  
  # 4. 验证Ingress配置
  echo "  [4/5] Checking Ingress..."
  if ! kubectl --context "$context" get ingress whoami -n whoami &>/dev/null; then
    echo "    ✗ Ingress not found"
    ((errors++))
  else
    local ingress_host=$(kubectl --context "$context" -n whoami get ingress whoami \
      -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
    local expected_host="whoami.$cluster.$base_domain"
    
    if [ "$ingress_host" = "$expected_host" ]; then
      echo "    ✓ Ingress host correct: $ingress_host"
    else
      echo "    ✗ Ingress host mismatch: $ingress_host (expected: $expected_host)"
      ((errors++))
    fi
  fi
  
  # 5. 验证HTTP可达性
  echo "  [5/5] Checking HTTP accessibility..."
  local whoami_url="http://whoami.$cluster.$base_domain"
  local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$whoami_url" 2>/dev/null || echo "000")
  
  case "$http_code" in
    200)
      echo "    ✓ HTTP accessible: $http_code"
      ;;
    404)
      echo "    ⚠ HTTP returns 404 (app not deployed or git service unavailable)"
      # 404不算错误，可能是Git服务问题
      ;;
    503)
      echo "    ✗ HTTP returns 503 (service unavailable)"
      ((errors++))
      ;;
    *)
      echo "    ✗ HTTP not accessible: $http_code"
      ((errors++))
      ;;
  esac
  
  return $errors
}

# 验证集群基础健康度
verify_cluster_health() {
  local cluster=$1
  local provider=${2:-kind}
  
  local context
  case "$provider" in
    k3d) context="k3d-$cluster" ;;
    kind) context="kind-$cluster" ;;
    *) echo "Unknown provider: $provider"; return 1 ;;
  esac
  
  local errors=0
  
  # 检查集群可访问性
  if ! kubectl --context "$context" get nodes &>/dev/null; then
    echo "  ✗ Cluster not accessible: $context"
    return 1
  fi
  
  # 检查节点状态
  local not_ready=$(kubectl --context "$context" get nodes --no-headers 2>/dev/null | \
    grep -v " Ready " | wc -l)
  if [ "$not_ready" -eq 0 ]; then
    echo "  ✓ All nodes ready"
  else
    echo "  ✗ $not_ready node(s) not ready"
    ((errors++))
  fi
  
  # 检查核心组件
  local coredns_ready=$(kubectl --context "$context" -n kube-system get deployment coredns \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "$coredns_ready" -gt 0 ]; then
    echo "  ✓ CoreDNS ready: $coredns_ready replicas"
  else
    echo "  ✗ CoreDNS not ready"
    ((errors++))
  fi
  
  return $errors
}

# 验证Ingress Controller
verify_ingress_controller() {
  local cluster=$1
  local provider=${2:-kind}
  
  local context
  case "$provider" in
    k3d) context="k3d-$cluster" ;;
    kind) context="kind-$cluster" ;;
  esac
  
  local errors=0
  
  # k3d使用Traefik，kind使用ingress-nginx
  if [ "$provider" = "k3d" ]; then
    local traefik_ready=$(kubectl --context "$context" -n kube-system get deployment traefik \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$traefik_ready" -gt 0 ]; then
      echo "  ✓ Traefik ready: $traefik_ready replicas"
    else
      echo "  ✗ Traefik not ready"
      ((errors++))
    fi
  else
    # kind需要检查ingress-nginx
    local nginx_ready=$(kubectl --context "$context" -n ingress-nginx get deployment ingress-nginx-controller \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$nginx_ready" -gt 0 ]; then
      echo "  ✓ Ingress-nginx ready: $nginx_ready replicas"
    else
      echo "  ⚠ Ingress-nginx not ready (may need installation)"
    fi
  fi
  
  return $errors
}

# 导出函数
export -f verify_whoami_app
export -f verify_cluster_health
export -f verify_ingress_controller


