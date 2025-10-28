#!/usr/bin/env bash
# HAProxy 配置测试
# 验证 HAProxy 配置文件正确性和路由规则

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"
. "$ROOT_DIR/scripts/lib.sh"

# 从容器中读取当前配置
CFG="/tmp/haproxy-test-cfg-$$.txt"
if ! docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg > "$CFG" 2>/dev/null; then
  echo "ERROR: Cannot read HAProxy configuration from container"
  exit 1
fi
trap "rm -f '$CFG'" EXIT

echo "=========================================="
echo "HAProxy Configuration Tests"
echo "=========================================="

# 1. HAProxy 配置语法测试
echo ""
echo "[1/5] Configuration Syntax"
if docker ps --filter name=haproxy-gw --format "{{.Names}}" | grep -q haproxy-gw; then
  validation_output=$(docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 2>&1)
  validation=$(echo "$validation_output" | grep -c "ALERT" 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  validation=$(echo "$validation" | sed 's/^00$/0/')
  validation=${validation:-0}
  
  assert_equals "0" "$validation" "HAProxy configuration syntax valid (no ALERT)"
  
  # 检查是否有警告（非致命，但应该注意）
  warnings=$(docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 2>&1 | grep -c "WARNING" 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
  warnings=$(echo "$warnings" | sed 's/^00$/0/')
  warnings=${warnings:-0}
  
  if [ "$warnings" -gt 0 ] 2>/dev/null; then
    echo "  ⚠ HAProxy configuration has $warnings warning(s)"
  fi
else
  echo "  ✗ HAProxy container not running"
  failed_tests=$((failed_tests + 1))
  total_tests=$((total_tests + 1))
fi

# 2. 动态路由配置测试
echo ""
echo "[2/5] Dynamic Routes Configuration"
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in environments.csv"
else
  for cluster in $clusters; do
    # 检查 ACL 定义（http 和 https frontend 各一个）
    acl_count=$(grep -c "acl host_$cluster" "$CFG" 2>/dev/null | tr -d ' \n' || echo "0")
    acl_count=${acl_count:-0}
    
    if [ "$acl_count" -ge 1 ] 2>/dev/null; then
      echo "  ✓ ACL for $cluster exists ($acl_count occurrences)"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ ACL for $cluster not found"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    # 检查 backend 定义（精确匹配：backend 名称后必须是空格或行尾）
    backend_count=$(grep -c "^backend be_${cluster}[[:space:]]*$" "$CFG" 2>/dev/null | tr -d ' \n' 2>/dev/null || echo "0")
    backend_count=$(echo "$backend_count" | sed 's/^00$/0/')
    backend_count=${backend_count:-0}
    assert_equals "1" "$backend_count" "Backend for $cluster exists"
  done
fi

# 3. Backend 端口配置测试（验证使用 NodePort）
# 注意：业务集群通过Ingress暴露，HAProxy直接访问集群的NodePort（Traefik）
# 架构：HAProxy -> server-0:NodePort -> Traefik Ingress -> whoami Service
# k3d和kind统一使用NodePort（移除hostPort避免多集群冲突）
echo ""
echo "[3/5] Backend Port Configuration"
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found in environments.csv"
else
  for cluster in $clusters; do
    # 从 CSV 读取 provider（第2列）来判断集群类型
    provider=$(awk -F, -v n="$cluster" 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print $2; exit}' "$ROOT_DIR/config/environments.csv" 2>/dev/null | tr -d ' \r\n')
    
    # k3d和kind集群：统一使用NodePort（移除hostPort避免多集群冲突）
    # HAProxy直接访问server-0的NodePort（Traefik Ingress Controller）
    expected_port=$(awk -F, -v n="$cluster" 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 && $1==n {print $3; exit}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "30080")
    
    if [ -z "$expected_port" ]; then
      echo "  ⚠ Could not determine expected port for $cluster"
      continue
    fi
    
    # 从 HAProxy 配置提取实际端口
    actual_port=$(awk -v cluster="$cluster" '
      /^backend be_'$cluster'[[:space:]]*$/ { in_backend=1; next }
      in_backend && /^[[:space:]]+server s1/ { 
        split($3, parts, ":")
        print parts[2]
        in_backend=0
        exit
      }
      /^backend / { in_backend=0 }
    ' "$CFG" 2>/dev/null | tr -d ' \n')
    
    if [ -z "$actual_port" ]; then
      echo "  ✗ Backend for $cluster not found in HAProxy config"
      failed_tests=$((failed_tests + 1))
    elif [ "$actual_port" = "$expected_port" ]; then
      echo "  ✓ $cluster backend uses correct node_port: $expected_port"
      passed_tests=$((passed_tests + 1))
    else
      echo "  ✗ $cluster backend port mismatch (expected: $expected_port, actual: $actual_port)"
      failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
  done
fi

# 4. 域名规则一致性测试（新格式：不含 provider）
echo ""
echo "[4/5] Domain Pattern Consistency"
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv" 2>/dev/null || echo "")

if [ -z "$clusters" ]; then
  echo "  ⚠ No business clusters found"
else
  for cluster in $clusters; do
    # 使用完整集群名以匹配 HAProxy ACL（避免 dev 和 dev-k3d 冲突）
    # HAProxy配置中的 \. 需要在grep中匹配为字面的反斜杠+点
    # 域名模式：.<cluster>.
    # 例如：dev -> .dev., dev-k3d -> .dev-k3d.
    expected_pattern="\\\\.$cluster\\\\."
    
    # 精确匹配：ACL 名称后面必须有空格
    acl_line=$(grep "acl host_${cluster}[[:space:]]" "$CFG" | head -1 2>/dev/null || echo "")
    if [ -n "$acl_line" ]; then
      if echo "$acl_line" | grep -q "$expected_pattern"; then
        echo "  ✓ $cluster domain pattern correct (.$cluster.)"
        passed_tests=$((passed_tests + 1))
      else
        echo "  ✗ $cluster domain pattern incorrect"
        echo "    Expected pattern in config: \\.$cluster\\."
        echo "    Actual ACL: $acl_line"
        failed_tests=$((failed_tests + 1))
      fi
      total_tests=$((total_tests + 1))
    fi
  done
fi

# 5. 核心服务路由测试
echo ""
echo "[5/5] Core Service Routes"
for service in argocd portainer git haproxy_stats; do
  service_display="${service/_/ }"
  if grep -q "acl host_$service" "$CFG" 2>/dev/null; then
    echo "  ✓ $service_display route configured"
    passed_tests=$((passed_tests + 1))
  else
    echo "  ✗ $service_display route not found"
    failed_tests=$((failed_tests + 1))
  fi
  total_tests=$((total_tests + 1))
done

print_summary

