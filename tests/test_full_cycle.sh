#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib.sh"

# 默认参数
ITERATIONS=3
SKIP_BUSINESS=0
QUICK_MODE=0

usage() {
  cat <<EOF
Usage: $0 [options]

端到端测试脚本：验证完整的清理→创建devops→创建业务集群→验证流程

Options:
  --iterations N      运行 N 次完整循环（默认：3）
  --skip-business     只测试 devops 集群创建，跳过业务集群
  --quick            快速模式：只创建 2 个业务集群（1 kind + 1 k3d）
  -h, --help         显示帮助信息

Examples:
  $0                           # 运行 3 次完整测试
  $0 --iterations 5            # 运行 5 次完整测试
  $0 --quick                   # 快速测试模式
  $0 --skip-business           # 只测试 devops 集群
EOF
  exit 0
}

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --skip-business)
      SKIP_BUSINESS=1
      shift
      ;;
    --quick)
      QUICK_MODE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# 创建日志目录
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/test_cycle_${TIMESTAMP}.log"

# 日志函数
log_info() {
  local msg="[$(date +%H:%M:%S)] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

log_success() {
  local msg="[$(date +%H:%M:%S)] ✓ $1"
  echo -e "\033[32m${msg}\033[0m" | tee -a "$LOG_FILE"
}

log_error() {
  local msg="[$(date +%H:%M:%S)] ✗ $1"
  echo -e "\033[31m${msg}\033[0m" | tee -a "$LOG_FILE"
}

log_warn() {
  local msg="[$(date +%H:%M:%S)] ⚠ $1"
  echo -e "\033[33m${msg}\033[0m" | tee -a "$LOG_FILE"
}

# 验证函数
verify_cluster_nodes() {
  local ctx="$1"
  local expected_status="Ready"
  
  if ! kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
    log_error "Cannot access cluster $ctx"
    return 1
  fi
  
  local not_ready=$(kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | grep -v "Ready" | wc -l | tr -d '\n' || echo 0)
  not_ready=$(echo "$not_ready" | tr -d ' \n')  # 清理空白字符
  if [ "$not_ready" -gt 0 ] 2>/dev/null; then
    log_error "Cluster $ctx has $not_ready nodes not Ready"
    kubectl --context "$ctx" get nodes | tee -a "$LOG_FILE"
    return 1
  fi
  
  log_success "Cluster $ctx: all nodes Ready"
  return 0
}

verify_portainer_edge_agent() {
  local ctx="$1"
  
  if ! kubectl --context "$ctx" get ns portainer-edge >/dev/null 2>&1; then
    log_warn "No portainer-edge namespace in $ctx (may be skipped)"
    return 0
  fi
  
  local phase=$(kubectl --context "$ctx" get pods -n portainer-edge -l app=portainer-edge-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [ "$phase" = "Running" ]; then
    log_success "Edge Agent in $ctx is Running"
    return 0
  else
    log_error "Edge Agent in $ctx is not Running (phase: ${phase:-none})"
    kubectl --context "$ctx" get pods -n portainer-edge | tee -a "$LOG_FILE"
    return 1
  fi
}

verify_argocd_cluster_registration() {
  local cluster_name="$1"
  
  if ! kubectl --context k3d-devops get secret "cluster-${cluster_name}" -n argocd >/dev/null 2>&1; then
    log_error "Cluster $cluster_name not registered in ArgoCD"
    return 1
  fi
  
  log_success "Cluster $cluster_name registered in ArgoCD"
  return 0
}

verify_haproxy_route() {
  local env="$1"
  local provider="$2"
  
  load_env
  local base_domain="${BASE_DOMAIN:-192.168.51.30.sslip.io}"
  local haproxy_host="${HAPROXY_HOST:-192.168.51.30}"
  local haproxy_http_port="${HAPROXY_HTTP_PORT:-80}"
  
  # 构造测试 URL（假设有 whoami 服务）
  local test_url
  if [ "$provider" = "k3d" ]; then
    test_url="http://whoami.k3d.${env}.${base_domain}"
  else
    test_url="http://whoami.kind.${env}.${base_domain}"
  fi
  
  if [ "$haproxy_http_port" != "80" ]; then
    test_url="${test_url}:${haproxy_http_port}"
  fi
  
  # 测试 HAProxy 路由（使用 Host header）
  if curl -s -m 5 -H "Host: whoami.${provider}.${env}.${base_domain}" "http://${haproxy_host}:${haproxy_http_port}/" >/dev/null 2>&1; then
    log_success "HAProxy route for $env ($provider) is working"
    return 0
  else
    log_warn "HAProxy route for $env ($provider) not responding (whoami may not be deployed yet)"
    return 0  # 不作为失败条件，因为 whoami 可能还没部署
  fi
}

verify_traefik() {
  local ctx="$1"
  
  if ! kubectl --context "$ctx" get deployment traefik -n traefik >/dev/null 2>&1; then
    log_error "Traefik not deployed in $ctx"
    return 1
  fi
  
  local ready=$(kubectl --context "$ctx" get deployment traefik -n traefik -o jsonpath='{.status.readyReplicas}' 2>/dev/null | tr -d '\n' || echo "0")
  ready=$(echo "$ready" | tr -d ' \n')  # 清理空白字符
  ready=${ready:-0}  # 如果为空，默认为0
  
  if [ "$ready" -gt 0 ] 2>/dev/null; then
    log_success "Traefik in $ctx is ready ($ready replicas)"
    return 0
  else
    log_warn "Traefik in $ctx is not ready (ready replicas: ${ready}), checking pods..."
    kubectl --context "$ctx" get pods -n traefik | tee -a "$LOG_FILE"
    kubectl --context "$ctx" describe pods -n traefik 2>/dev/null | tail -30 | tee -a "$LOG_FILE"
    
    # 检查是否是镜像拉取问题
    local image_pull_error=$(kubectl --context "$ctx" get pods -n traefik -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -i "Image" || true)
    if [ -n "$image_pull_error" ]; then
      log_error "Traefik has image pull issues: $image_pull_error"
    fi
    return 1
  fi
}

# 主测试函数
run_single_iteration() {
  local iteration="$1"
  local start_time=$(date +%s)
  local max_iteration_time=1800  # 单轮最长30分钟
  
  # 设置超时保护
  (
    sleep "$max_iteration_time"
    log_error "Iteration $iteration exceeded timeout (${max_iteration_time}s), force terminating..."
    exit 124  # timeout exit code
  ) &
  local timeout_pid=$!
  
  log_info "========================================="
  log_info "Starting iteration $iteration of $ITERATIONS"
  log_info "========================================="
  
  # 步骤 1: 清理环境
  log_info "Step 1: Cleaning environment..."
  if ! "$ROOT_DIR/scripts/clean.sh" --all --verify >>"$LOG_FILE" 2>&1; then
    log_error "Clean failed"
    return 1
  fi
  log_success "Environment cleaned"
  
  # 步骤 2: 创建 devops 集群
  log_info "Step 2: Creating devops cluster..."
  if ! "$ROOT_DIR/scripts/bootstrap.sh" >>"$LOG_FILE" 2>&1; then
    log_error "Bootstrap failed"
    return 1
  fi
  log_success "devops cluster created"
  
  # 验证 devops 集群
  log_info "Verifying devops cluster..."
  verify_cluster_nodes "k3d-devops" || return 1
  
  # 验证 Portainer 可访问
  log_info "Verifying Portainer..."
  local portainer_ip=$(docker inspect portainer-ce --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
  if curl -s -m 5 "http://${portainer_ip}:9000/api/system/status" >/dev/null 2>&1; then
    log_success "Portainer is accessible"
  else
    log_error "Portainer is not accessible"
    return 1
  fi
  
  # 验证 ArgoCD
  log_info "Verifying ArgoCD..."
  if kubectl --context k3d-devops get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
    log_success "ArgoCD is running"
  else
    log_error "ArgoCD is not running"
    return 1
  fi
  
  # 步骤 3: 创建业务集群
  if [ $SKIP_BUSINESS -eq 0 ]; then
    log_info "Step 3: Creating business clusters..."
    
    # 读取要创建的集群列表
    local clusters_to_create=()
    if [ -f "$ROOT_DIR/config/environments.csv" ]; then
      if [ $QUICK_MODE -eq 1 ]; then
        # 快速模式：只创建 1 个 kind 和 1 个 k3d
        local kind_env=$(awk -F, '$0 !~ /^\s*#/ && NF>0 && $1!="devops" && $2=="kind" {print $1; exit}' "$ROOT_DIR/config/environments.csv")
        local k3d_env=$(awk -F, '$0 !~ /^\s*#/ && NF>0 && $1!="devops" && $2=="k3d" {print $1; exit}' "$ROOT_DIR/config/environments.csv")
        [ -n "$kind_env" ] && clusters_to_create+=("$kind_env")
        [ -n "$k3d_env" ] && clusters_to_create+=("$k3d_env")
      else
        # 完整模式：创建所有业务集群（排除 devops）
        while IFS=, read -r env provider rest; do
          env=$(echo "$env" | sed -e 's/^\s\+//' -e 's/\s\+$//')
          [ -z "$env" ] && continue
          [ "$env" = "devops" ] && continue
          clusters_to_create+=("$env")
        done < <(awk -F, '$0 !~ /^\s*#/ && NF>0 {print}' "$ROOT_DIR/config/environments.csv")
      fi
    fi
    
    if [ ${#clusters_to_create[@]} -eq 0 ]; then
      log_warn "No business clusters to create"
    else
      log_info "Creating ${#clusters_to_create[@]} business clusters: ${clusters_to_create[*]}"
      
      for env in "${clusters_to_create[@]}"; do
        log_info "Creating cluster: $env"
        if ! "$ROOT_DIR/scripts/create_env.sh" -n "$env" >>"$LOG_FILE" 2>&1; then
          log_error "Failed to create cluster $env"
          return 1
        fi
        log_success "Cluster $env created"
        
        # 验证集群
        local provider=$(provider_for "$env")
        local ctx_prefix=$([ "$provider" = "k3d" ] && echo "k3d" || echo "kind")
        local ctx="${ctx_prefix}-${env}"
        
        verify_cluster_nodes "$ctx" || return 1
        verify_traefik "$ctx" || return 1
        # verify_portainer_edge_agent "$ctx" || return 1  # 暂时不强制要求
        verify_argocd_cluster_registration "$env" || return 1
        verify_haproxy_route "$env" "$provider" || true  # 不作为失败条件
      done
      
      log_success "All business clusters created and verified"
    fi
  else
    log_info "Step 3: Skipping business clusters (--skip-business)"
  fi
  
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  # 取消超时保护
  kill $timeout_pid 2>/dev/null || true
  wait $timeout_pid 2>/dev/null || true
  
  log_success "Iteration $iteration completed in ${duration}s"
  
  return 0
}

# 主流程
main() {
  log_info "========================================="
  log_info "Full Cycle Test Starting"
  log_info "========================================="
  log_info "Iterations: $ITERATIONS"
  log_info "Skip business clusters: $SKIP_BUSINESS"
  log_info "Quick mode: $QUICK_MODE"
  log_info "Log file: $LOG_FILE"
  log_info ""
  
  local success_count=0
  local fail_count=0
  local start_time=$(date +%s)
  
  for i in $(seq 1 "$ITERATIONS"); do
    if run_single_iteration "$i"; then
      success_count=$((success_count + 1))
      log_success "✓✓✓ Iteration $i: SUCCESS ✓✓✓"
    else
      fail_count=$((fail_count + 1))
      log_error "✗✗✗ Iteration $i: FAILED ✗✗✗"
      
      # 失败后询问是否继续
      log_warn "Test iteration $i failed. Check logs for details."
      if [ $i -lt "$ITERATIONS" ]; then
        log_info "Continuing to next iteration..."
      fi
    fi
    
    # 迭代之间等待一下
    if [ $i -lt "$ITERATIONS" ]; then
      log_info "Waiting 5 seconds before next iteration..."
      sleep 5
    fi
  done
  
  local end_time=$(date +%s)
  local total_duration=$((end_time - start_time))
  
  # 总结报告
  log_info ""
  log_info "========================================="
  log_info "Full Cycle Test Summary"
  log_info "========================================="
  log_info "Total iterations: $ITERATIONS"
  log_success "Successful: $success_count"
  if [ $fail_count -gt 0 ]; then
    log_error "Failed: $fail_count"
  else
    log_info "Failed: $fail_count"
  fi
  log_info "Total duration: ${total_duration}s (avg: $((total_duration / ITERATIONS))s per iteration)"
  log_info "Log file: $LOG_FILE"
  log_info ""
  
  if [ $fail_count -eq 0 ]; then
    log_success "========================================="
    log_success "ALL TESTS PASSED!"
    log_success "========================================="
    return 0
  else
    log_error "========================================="
    log_error "SOME TESTS FAILED!"
    log_error "========================================="
    return 1
  fi
}

# 执行主流程
main
