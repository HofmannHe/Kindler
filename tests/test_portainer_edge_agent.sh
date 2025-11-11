#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# 测试 Portainer Edge Agent 连接状态
# 用法: scripts/test_portainer_edge_agent.sh [cluster_name]

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# 默认测试所有集群
CLUSTER_NAMES="${1:-dev dev-k3d}"

test_edge_agent_connection() {
    local cluster_name="$1"
    local provider="k3d"
    
    # 确定 provider
    if [[ "$cluster_name" == "dev" ]]; then
        provider="kind"
    fi
    
    echo "=== 测试集群: $cluster_name ($provider) ==="
    
    # 检查集群是否存在
    if [[ "$provider" == "k3d" ]]; then
        if ! k3d cluster list | grep -q "$cluster_name"; then
            echo "❌ 集群 $cluster_name 不存在"
            return 1
        fi
    else
        if ! kind get clusters | grep -q "$cluster_name"; then
            echo "❌ 集群 $cluster_name 不存在"
            return 1
        fi
    fi
    
    # 检查 Edge Agent Pod 状态
    local context_name
    if [[ "$provider" == "k3d" ]]; then
        context_name="k3d-$cluster_name"
    else
        context_name="kind-$cluster_name"
    fi
    
    echo "检查 Edge Agent Pod 状态..."
    local pod_status
    pod_status=$(kubectl --context "$context_name" get pods -n portainer-edge -l app=portainer-edge-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    
    if [[ "$pod_status" == "Running" ]]; then
        echo "✅ Edge Agent Pod 状态: $pod_status"
    else
        echo "❌ Edge Agent Pod 状态: $pod_status"
        return 1
    fi
    
    # 检查 Edge Agent 日志中的连接状态
    echo "检查 Edge Agent 连接状态..."
    local recent_logs
    recent_logs=$(kubectl --context "$context_name" logs -n portainer-edge deployment/portainer-edge-agent --tail 10 2>/dev/null || echo "")
    
    if echo "$recent_logs" | grep -q "no route to host\|connection refused\|timeout"; then
        echo "❌ Edge Agent 连接失败"
        echo "最近的错误日志:"
        echo "$recent_logs" | grep -E "(no route to host|connection refused|timeout)" | tail -3
        return 1
    elif echo "$recent_logs" | grep -q "polling\|heartbeat\|status"; then
        echo "✅ Edge Agent 连接正常"
    else
        echo "⚠️  Edge Agent 状态未知，需要进一步检查"
        echo "最近的日志:"
        echo "$recent_logs" | tail -3
    fi
    
    # 检查 Portainer 中的集群状态（需要登录）
    echo "检查 Portainer 中的集群状态..."
    local portainer_status
    portainer_status=$(curl -k -s https://portainer.devops.192.168.51.30.sslip.io/api/endpoints 2>/dev/null | jq -r '.[] | select(.Name=="'${cluster_name//-}'") | .Status' 2>/dev/null || echo "Unknown")
    
    if [[ "$portainer_status" == "1" ]]; then
        echo "✅ Portainer 中集群状态: 健康"
    elif [[ "$portainer_status" == "0" ]]; then
        echo "❌ Portainer 中集群状态: 不健康"
        return 1
    else
        echo "⚠️  Portainer 中集群状态: 未知 ($portainer_status)"
    fi
    
    echo "✅ 集群 $cluster_name 的 Edge Agent 测试通过"
    return 0
}

main() {
    echo "=== Portainer Edge Agent 连接测试 ==="
    echo "测试集群: $CLUSTER_NAMES"
    echo
    
    local failed_clusters=()
    local passed_clusters=()
    
    for cluster_name in $CLUSTER_NAMES; do
        if test_edge_agent_connection "$cluster_name"; then
            passed_clusters+=("$cluster_name")
        else
            failed_clusters+=("$cluster_name")
        fi
        echo
    done
    
    echo "=== 测试结果汇总 ==="
    echo "✅ 通过的集群: ${passed_clusters[*]:-无}"
    echo "❌ 失败的集群: ${failed_clusters[*]:-无}"
    
    if [[ ${#failed_clusters[@]} -eq 0 ]]; then
        echo "🎉 所有集群的 Edge Agent 连接测试通过！"
        return 0
    else
        echo "⚠️  有 ${#failed_clusters[@]} 个集群的 Edge Agent 连接失败"
        return 1
    fi
}

main "$@"

