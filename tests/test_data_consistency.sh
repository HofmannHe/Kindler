#!/usr/bin/env bash
# 完整的数据一致性测试脚本
# 验证数据库、集群、ApplicationSet、Portainer、ArgoCD 的一致性

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

echo "=========================================="
echo "  数据一致性完整测试"
echo "=========================================="
echo ""

PASSED=0
FAILED=0

# 测试函数
test_check() {
  local name="$1"
  local result="$2"
  
  if [ "$result" -eq 0 ]; then
    echo "  ✓ $name"
    PASSED=$((PASSED + 1))
  else
    echo "  ✗ $name"
    FAILED=$((FAILED + 1))
  fi
}

# 1. 验证数据库可用性
echo "[测试 1] 数据库可用性"
if sqlite_is_available 2>/dev/null; then
  test_check "SQLite 数据库可用" 0
else
  test_check "SQLite 数据库可用" 1
fi
echo ""

# 2. 验证数据库与集群一致性
echo "[测试 2] 数据库与集群一致性"
echo "  检查数据库记录..."

db_clusters=$(sqlite_query "SELECT name, provider FROM clusters WHERE name != 'devops' ORDER BY name;" 2>/dev/null || echo "")
db_count=0
match_count=0

while IFS='|' read -r name provider; do
  [ -z "$name" ] && continue
  db_count=$((db_count + 1))
  
  # 构建 context
  ctx=""
  if [ "$provider" = "k3d" ]; then
    ctx="k3d-${name}"
  else
    ctx="kind-${name}"
  fi
  
  # 验证集群是否存在
  if kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
    echo "    ✓ $name ($provider) - 数据库记录存在且集群存在"
    match_count=$((match_count + 1))
  else
    echo "    ✗ $name ($provider) - 数据库记录存在但集群不存在"
    FAILED=$((FAILED + 1))
  fi
done < <(echo "$db_clusters")

if [ $db_count -eq 0 ]; then
  echo "    ℹ 数据库中没有业务集群记录"
fi

if [ $db_count -eq $match_count ] && [ $db_count -gt 0 ]; then
  test_check "数据库与集群一致 ($match_count/$db_count)" 0
else
  test_check "数据库与集群一致 ($match_count/$db_count)" 1
fi
echo ""

# 3. 验证 ApplicationSet 准确性
echo "[测试 3] ApplicationSet 准确性"
echo "  同步 ApplicationSet..."

if [ -f "$ROOT_DIR/scripts/sync_applicationset.sh" ]; then
  if "$ROOT_DIR/scripts/sync_applicationset.sh" >/tmp/applicationset_sync.log 2>&1; then
    test_check "ApplicationSet 同步成功" 0
    
    # 检查生成的 ApplicationSet 文件
    if [ -f "$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml" ]; then
      # 提取集群名称
      appset_clusters=$(grep -E "^\s+- env:" "$ROOT_DIR/manifests/argocd/whoami-applicationset.yaml" | sed 's/.*env: //' | sort || echo "")
      appset_count=$(echo "$appset_clusters" | grep -c '^' || echo "0")
      
      echo "    ApplicationSet 包含 $appset_count 个集群"
      
      # 验证每个 ApplicationSet 中的集群是否实际存在
      appset_valid=0
      for cluster in $appset_clusters; do
        # 从数据库获取 provider
        provider=$(sqlite_query "SELECT provider FROM clusters WHERE name = '$cluster';" 2>/dev/null | head -1 | tr -d ' \n' || echo "")
        if [ -z "$provider" ]; then
          echo "    ✗ $cluster - 在 ApplicationSet 中但不在数据库"
          FAILED=$((FAILED + 1))
          continue
        fi
        
        ctx=""
        if [ "$provider" = "k3d" ]; then
          ctx="k3d-${cluster}"
        else
          ctx="kind-${cluster}"
        fi
        
        if kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
          echo "    ✓ $cluster - ApplicationSet 中存在且集群存在"
          appset_valid=$((appset_valid + 1))
        else
          echo "    ✗ $cluster - ApplicationSet 中存在但集群不存在"
          FAILED=$((FAILED + 1))
        fi
      done
      
      if [ $appset_count -eq $appset_valid ] && [ $appset_count -gt 0 ]; then
        test_check "ApplicationSet 准确性 ($appset_valid/$appset_count)" 0
      else
        test_check "ApplicationSet 准确性 ($appset_valid/$appset_count)" 1
      fi
    else
      echo "    ⚠ ApplicationSet 文件未生成"
      test_check "ApplicationSet 文件存在" 1
    fi
  else
    test_check "ApplicationSet 同步成功" 1
    echo "    错误日志:"
    tail -20 /tmp/applicationset_sync.log | sed 's/^/      /'
  fi
else
  echo "    ⚠ sync_applicationset.sh 不存在"
  test_check "sync_applicationset.sh 存在" 1
fi
echo ""

# 4. 验证 ArgoCD Applications
echo "[测试 4] ArgoCD Applications"
if kubectl --context k3d-devops get ns argocd >/dev/null 2>&1; then
  argocd_apps=$(kubectl --context k3d-devops get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  argocd_count=$(echo "$argocd_apps" | wc -w || echo "0")
  
  if [ "$argocd_count" -gt 0 ]; then
    echo "    ArgoCD 中有 $argocd_count 个 Applications"
    
    # 验证每个 Application 对应的集群是否存在
    for app in $argocd_apps; do
      cluster=$(kubectl --context k3d-devops get application "$app" -n argocd -o jsonpath='{.spec.destination.name}' 2>/dev/null || echo "")
      if [ -n "$cluster" ]; then
        # 尝试找到对应的 context
        ctx=""
        for existing_ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -E "k3d-|kind-" || true); do
          if echo "$existing_ctx" | grep -q "$cluster"; then
            ctx="$existing_ctx"
            break
          fi
        done
        
        if [ -n "$ctx" ] && kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
          echo "    ✓ Application $app -> 集群 $cluster 存在"
        else
          echo "    ✗ Application $app -> 集群 $cluster 不存在"
          FAILED=$((FAILED + 1))
        fi
      fi
    done
  else
    echo "    ℹ ArgoCD 中没有 Applications"
  fi
  
  test_check "ArgoCD 可访问" 0
else
  echo "    ⚠ ArgoCD namespace 不存在"
  test_check "ArgoCD 可访问" 1
fi
echo ""

# 5. 验证幂等性
echo "[测试 5] 幂等性测试"
echo "  多次运行 cleanup_nonexistent_clusters.sh..."

if [ -f "$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" ]; then
  # 第一次运行
  result1=$(./scripts/cleanup_nonexistent_clusters.sh 2>&1 | tail -1)
  # 第二次运行
  result2=$(./scripts/cleanup_nonexistent_clusters.sh 2>&1 | tail -1)
  
  if [ "$result1" = "$result2" ]; then
    test_check "cleanup_nonexistent_clusters.sh 幂等性" 0
  else
    test_check "cleanup_nonexistent_clusters.sh 幂等性" 1
    echo "    第一次: $result1"
    echo "    第二次: $result2"
  fi
else
  test_check "cleanup_nonexistent_clusters.sh 存在" 1
fi
echo ""

# 汇总结果
echo "=========================================="
echo "  测试结果汇总"
echo "=========================================="
echo "  通过: $PASSED"
echo "  失败: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
  echo "=========================================="
  echo "✅ 所有测试通过！"
  echo "=========================================="
  exit 0
else
  echo "=========================================="
  echo "✗ 有 $FAILED 个测试失败"
  echo "=========================================="
  exit 1
fi
