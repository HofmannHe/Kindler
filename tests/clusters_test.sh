#!/usr/bin/env bash
# 集群状态测试
# 验证 Kubernetes 集群健康状态

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"
. "$ROOT_DIR/scripts/lib.sh"

echo "=========================================="
echo "Cluster State Tests"
echo "=========================================="

# 获取所有集群（包括 devops）
all_clusters=$(awk -F, 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$all_clusters" ]; then
  echo "No clusters found in environments.csv"
  exit 1
fi

cluster_count=0
for cluster in $all_clusters; do
  cluster_count=$((cluster_count + 1))
  provider=$(provider_for "$cluster")
  # 构建 context 名称
  if [ "$provider" = "k3d" ]; then
    ctx="k3d-$cluster"
  else
    ctx="kind-$cluster"
  fi
  
  echo ""
  echo "[$cluster_count] Cluster: $cluster ($provider)"
  
  # 检查 context 是否存在
  if ! kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
    echo "  ✗ Context $ctx not found"
    failed_tests=$((failed_tests + 3))
    total_tests=$((total_tests + 3))
    continue
  fi
  
  # 1. 节点就绪状态
  ready_status=$(kubectl --context "$ctx" get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  total_nodes=$(kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | wc -l)
  ready_nodes=$(echo "$ready_status" | grep -o "True" | wc -l)
  
  assert_equals "$total_nodes" "$ready_nodes" "$cluster nodes ready ($ready_nodes/$total_nodes)"
  
  # 2. 核心组件运行状态
  failed_pods=$(kubectl --context "$ctx" get pods -n kube-system --no-headers 2>/dev/null | grep -Ev "Running|Completed" | wc -l || echo "999")
  assert_equals "0" "$failed_pods" "$cluster kube-system pods healthy"
  
  # 3. Edge Agent 状态（业务集群）
  if [ "$cluster" != "devops" ]; then
    if kubectl --context "$ctx" get deployment portainer-edge-agent -n portainer-edge >/dev/null 2>&1; then
      agent_ready=$(kubectl --context "$ctx" get deployment portainer-edge-agent -n portainer-edge -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      assert_equals "1" "$agent_ready" "$cluster Edge Agent ready"
    else
      echo "  ⚠ $cluster Edge Agent not deployed"
    fi
  fi
  
  # 4. whoami 应用状态（业务集群）
  if [ "$cluster" != "devops" ]; then
    whoami_pods=$(kubectl --context "$ctx" get pods -A -l app=whoami -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
    if [ -n "$whoami_pods" ]; then
      running_count=$(echo "$whoami_pods" | grep -o "Running" | wc -l)
      if [ "$running_count" -gt 0 ]; then
        echo "  ✓ $cluster whoami app running ($running_count pod(s))"
        passed_tests=$((passed_tests + 1))
      else
        echo "  ✗ $cluster whoami app not running"
        failed_tests=$((failed_tests + 1))
      fi
      total_tests=$((total_tests + 1))
    fi
  fi
done

print_summary

