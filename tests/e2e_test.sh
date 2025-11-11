#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# 加载配置
if [ -f "$ROOT_DIR/config/clusters.env" ]; then
	. "$ROOT_DIR/config/clusters.env"
fi
: "${BASE_DOMAIN:=192.168.51.30.sslip.io}"
: "${HAPROXY_HOST:=192.168.51.30}"

usage() {
	cat >&2 <<EOF
Usage: $0 [--rounds <N>] [--skip-cleanup] [--verify]

端到端测试：连续执行多轮完整的清理→创建→验证流程

选项:
  --rounds <N>        测试轮数（默认：3）
  --skip-cleanup      跳过每轮前的清理（用于调试）
  --verify            在清理后验证环境干净
  -h, --help          显示帮助信息
EOF
	exit 1
}

# 参数解析
ROUNDS=3
SKIP_CLEANUP=0
VERIFY=0

while [[ $# -gt 0 ]]; do
	case $1 in
	--rounds)
		ROUNDS="$2"
		shift 2
		;;
	--skip-cleanup)
		SKIP_CLEANUP=1
		shift
		;;
	--verify)
		VERIFY=1
		shift
		;;
	-h | --help)
		usage
		;;
	*)
		echo "Unknown option: $1" >&2
		usage
		;;
	esac
done

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_fail() { echo -e "${RED}✗${NC} $*"; }

# 读取业务集群列表（排除 devops）
read_business_clusters() {
	local csv="$ROOT_DIR/config/environments.csv"
	[ -f "$csv" ] || return 1
	awk -F, '$0 !~ /^[[:space:]]*#/ && NF>0 && $1!="devops" {print $1","$2}' "$csv" | head -6
}

# 验证集群可访问性
verify_cluster() {
	local env="$1" provider="$2"
	local ctx
	if [ "$provider" = "k3d" ]; then
		ctx="k3d-${env}"
	else
		ctx="kind-${env}"
	fi

	if kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
		log_success "Cluster $env is accessible"
		return 0
	else
		log_fail "Cluster $env is NOT accessible"
		return 1
	fi
}

# 验证 HAProxy 路由
verify_haproxy_route() {
	local env="$1" provider="$2"
	local test_host
	
	# 构建测试域名（假设有 whoami 服务）
	if [ "$provider" = "k3d" ]; then
		test_host="whoami.k3d.${env%-k3d}.${BASE_DOMAIN}"
	else
		test_host="whoami.kind.${env}.${BASE_DOMAIN}"
	fi

	# 简单检查 HAProxy 配置中是否有该环境的路由
	if grep -q "host_${env}" "$ROOT_DIR/compose/infrastructure/haproxy.cfg"; then
		log_success "HAProxy route for $env exists"
		return 0
	else
		log_warn "HAProxy route for $env not found (may not be configured yet)"
		return 1
	fi
}

# 验证 Portainer 注册
verify_portainer_registration() {
	local env="$1"
	
	# 检查 Edge Agent 是否运行
	local ctx provider
	provider=$(awk -F, -v e="$env" '$0 !~ /^[[:space:]]*#/ && NF>0 && $1==e {print $2; exit}' "$ROOT_DIR/config/environments.csv" | tr -d ' ')
	if [ "$provider" = "k3d" ]; then
		ctx="k3d-${env}"
	else
		ctx="kind-${env}"
	fi
	
	# 检查 namespace 是否存在
	if ! kubectl --context "$ctx" get namespace portainer-edge >/dev/null 2>&1; then
		log_fail "Portainer namespace missing in $env"
		return 1
	fi
	
	# 检查 Secret 是否存在
	if ! kubectl --context "$ctx" get secret portainer-edge-creds -n portainer-edge >/dev/null 2>&1; then
		log_fail "Portainer credentials Secret missing in $env"
		return 1
	fi
	
	# 检查 Edge Agent pod 状态
	local pod_status
	pod_status=$(kubectl --context "$ctx" get pods -n portainer-edge -l app=portainer-edge-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
	
	if [ "$pod_status" = "Running" ]; then
		log_success "Portainer Edge Agent running in $env"
		return 0
	else
		log_fail "Portainer Edge Agent not running in $env (status: $pod_status)"
		# 显示详细信息帮助调试
		kubectl --context "$ctx" get pods -n portainer-edge -l app=portainer-edge-agent 2>/dev/null || true
		return 1
	fi
}

# 执行一轮完整测试
run_round() {
	local round="$1"
	local start_time end_time duration
	start_time=$(date +%s)

	echo ""
	echo "=========================================="
	log_info "Round $round/$ROUNDS"
	echo "=========================================="
	echo ""

	# 步骤 1: 清理环境
	if [ "$SKIP_CLEANUP" = "0" ]; then
		log_info "Step 1: Cleaning environment..."
		if [ "$VERIFY" = "1" ]; then
			if ! "$ROOT_DIR/scripts/clean.sh" --all --verify; then
				log_error "Cleanup verification failed"
				return 1
			fi
		else
			if ! "$ROOT_DIR/scripts/clean.sh" --all; then
				log_error "Cleanup failed"
				return 1
			fi
		fi
		log_success "Environment cleaned"
	else
		log_warn "Skipping cleanup (--skip-cleanup specified)"
	fi

	# 步骤 2: 启动基础环境
	log_info "Step 2: Bootstrapping infrastructure..."
	if ! "$ROOT_DIR/scripts/bootstrap.sh"; then
		log_error "Bootstrap failed"
		return 1
	fi
	log_success "Infrastructure bootstrapped"

	# 验证 devops 集群
	if ! kubectl --context k3d-devops get nodes >/dev/null 2>&1; then
		log_error "devops cluster not accessible"
		return 1
	fi
	log_success "devops cluster is accessible"

	# 验证 Portainer
	if ! docker ps --format '{{.Names}}' | grep -q '^portainer-ce$'; then
		log_error "Portainer is not running"
		return 1
	fi
	log_success "Portainer is running"

	# 验证 HAProxy
	if ! docker ps --format '{{.Names}}' | grep -q '^haproxy-gw$'; then
		log_error "HAProxy is not running"
		return 1
	fi
	log_success "HAProxy is running"

	# 步骤 3: 创建业务集群
	log_info "Step 3: Creating business clusters (parallel)..."
	if ! "$ROOT_DIR/tools/maintenance/batch_create_envs.sh"; then
		log_error "Batch cluster creation failed"
		return 1
	fi
	log_success "All business clusters created"

	# 步骤 4: 验证集群
	log_info "Step 4: Verifying clusters..."
	local errors=0
	while IFS=, read -r env provider; do
		if ! verify_cluster "$env" "$provider"; then
			errors=$((errors + 1))
		fi
	done < <(read_business_clusters)

	if [ $errors -gt 0 ]; then
		log_error "$errors cluster(s) failed verification"
		return 1
	fi
	log_success "All clusters verified"

	# 步骤 5: 验证 HAProxy 路由
	log_info "Step 5: Verifying HAProxy routes..."
	while IFS=, read -r env provider; do
		verify_haproxy_route "$env" "$provider" || true
	done < <(read_business_clusters)

	# 步骤 6: 验证 Portainer 注册（强制要求）
	log_info "Step 6: Verifying Portainer registrations..."
	local portainer_errors=0
	while IFS=, read -r env provider; do
		# 只检查配置为注册的环境
		reg=$(awk -F, -v e="$env" '$0 !~ /^[[:space:]]*#/ && NF>0 && $1==e {print $5; exit}' "$ROOT_DIR/config/environments.csv" | tr -d ' ' | tr 'A-Z' 'a-z')
		if [ "$reg" = "true" ] || [ "$reg" = "1" ]; then
			if ! verify_portainer_registration "$env"; then
				portainer_errors=$((portainer_errors + 1))
			fi
		fi
	done < <(read_business_clusters)
	
	if [ $portainer_errors -gt 0 ]; then
		log_error "$portainer_errors cluster(s) failed Portainer registration"
		return 1
	fi
	log_success "All Portainer registrations verified"

	end_time=$(date +%s)
	duration=$((end_time - start_time))

	echo ""
	log_success "Round $round completed successfully in ${duration}s"
	echo ""
	return 0
}

# 主流程
main() {
	echo "=================================================="
	log_info "E2E Test: $ROUNDS rounds"
	echo "=================================================="

	local failed_rounds=0

	for round in $(seq 1 "$ROUNDS"); do
		if ! run_round "$round"; then
			log_fail "Round $round FAILED"
			failed_rounds=$((failed_rounds + 1))
			# 继续下一轮测试（不中断）
		else
			log_success "Round $round PASSED"
		fi
	done

	echo ""
	echo "=================================================="
	log_info "E2E Test Summary"
	echo "=================================================="
	echo "Total rounds: $ROUNDS"
	echo "Passed: $((ROUNDS - failed_rounds))"
	echo "Failed: $failed_rounds"
	echo ""

	if [ $failed_rounds -eq 0 ]; then
		log_success "All rounds passed! ✓"
		exit 0
	else
		log_fail "$failed_rounds round(s) failed"
		exit 1
	fi
}

main "$@"
