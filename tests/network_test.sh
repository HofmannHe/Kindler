#!/usr/bin/env bash
# 网络连通性测试
# 验证网络架构和容器互联性

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"

echo "=========================================="
echo "Network Connectivity Tests"
echo "=========================================="

# 1. HAProxy 网络连接测试
echo ""
echo "[1/5] HAProxy Network Connections"
if docker ps --filter name=haproxy-gw --format "{{.Names}}" | grep -q haproxy-gw; then
  networks=$(docker inspect haproxy-gw --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null || echo "")
  
  assert_contains "$networks" "k3d-shared" "HAProxy connected to k3d-shared network"
  assert_contains "$networks" "infrastructure" "HAProxy connected to infrastructure network"
  
  # 检查是否连接到业务集群网络
  business_nets=$(echo "$networks" | grep -o "k3d-[a-z0-9-]*" | grep -v "k3d-shared" | wc -l)
  assert_greater_than "0" "$business_nets" "HAProxy connected to business cluster networks ($business_nets)"
else
  echo "  ✗ HAProxy container not running"
  failed_tests=$((failed_tests + 3))
  total_tests=$((total_tests + 3))
fi

# 2. Portainer 网络连接测试
echo ""
echo "[2/5] Portainer Network Connections"
if docker ps --filter name=portainer-ce --format "{{.Names}}" | grep -q portainer-ce; then
  networks=$(docker inspect portainer-ce --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null || echo "")
  
  assert_contains "$networks" "k3d-shared" "Portainer connected to k3d-shared network"
  assert_contains "$networks" "infrastructure" "Portainer connected to infrastructure network"
else
  echo "  ✗ Portainer container not running"
  failed_tests=$((failed_tests + 2))
  total_tests=$((total_tests + 2))
fi

# 3. devops 集群跨网络访问测试
echo ""
echo "[3/5] Devops Cross-Network Access"
devops_container="k3d-devops-server-0"
if docker ps --filter name="$devops_container" --format "{{.Names}}" | grep -q "$devops_container"; then
  # 动态读取所有 k3d 业务集群
  k3d_clusters=$(awk -F, 'NR>1 && $1!="devops" && $2~/k3d/ && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")
  
  if [ -z "$k3d_clusters" ]; then
    echo "  ⚠ No k3d business clusters found in environments.csv"
  else
    for cluster in $k3d_clusters; do
      net="k3d-$cluster"
      if docker network inspect "$net" >/dev/null 2>&1; then
        containers=$(docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
        if echo "$containers" | grep -q "$devops_container"; then
          echo "  ✓ devops connected to $net"
          passed_tests=$((passed_tests + 1))
        else
          echo "  ✗ devops not connected to $net"
          failed_tests=$((failed_tests + 1))
        fi
        total_tests=$((total_tests + 1))
      else
        echo "  ⚠ Network $net does not exist (cluster may not be created yet)"
      fi
    done
  fi
else
  echo "  ⚠ devops cluster not running, skipping cross-network tests"
fi

# 4. HAProxy 到 devops 集群连通性测试
echo ""
echo "[4/5] HAProxy to Devops Connectivity"
if docker ps --filter name=haproxy-gw --format "{{.Names}}" | grep -q haproxy-gw; then
  devops_ip=$(docker network inspect k3d-shared --format '{{range .Containers}}{{if eq .Name "k3d-devops-server-0"}}{{.IPv4Address}}{{end}}{{end}}' 2>/dev/null | cut -d/ -f1 || echo "")
  
  if [ -n "$devops_ip" ]; then
    if docker exec haproxy-gw ping -c 1 -W 2 "$devops_ip" >/dev/null 2>&1; then
      echo "  ✓ HAProxy can ping devops cluster ($devops_ip)"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ HAProxy cannot ping devops cluster ($devops_ip)"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  else
    echo "  ⚠ Could not determine devops IP"
  fi
else
  echo "  ✗ HAProxy not running"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

# 5. 业务集群网络隔离测试
echo ""
echo "[5/5] Business Cluster Network Isolation"
subnets=""
subnet_count=0

# 动态读取所有 k3d 业务集群
k3d_clusters=$(awk -F, 'NR>1 && $1!="devops" && $2~/k3d/ && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$k3d_clusters" ]; then
  echo "  ⚠ No k3d business clusters found in environments.csv"
else
  for cluster in $k3d_clusters; do
    net="k3d-$cluster"
    if docker network inspect "$net" >/dev/null 2>&1; then
      subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "")
      if [ -n "$subnet" ]; then
        subnets="$subnets $subnet"
        subnet_count=$((subnet_count + 1))
      fi
    fi
  done
  
  if [ -n "$subnets" ]; then
    unique_subnets=$(echo "$subnets" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)
    
    if [ "$unique_subnets" -eq "$subnet_count" ]; then
      echo "  ✓ All business clusters use different subnets ($unique_subnets unique)"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ Subnet conflict detected ($unique_subnets unique out of $subnet_count)"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  else
    echo "  ⚠ No business cluster subnets found"
  fi
fi

print_summary

