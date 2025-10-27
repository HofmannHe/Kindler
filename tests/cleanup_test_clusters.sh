#!/usr/bin/env bash
# 清理所有测试集群（test-*, rttr-*）
# 用途：清理测试过程中遗留的集群资源，防止数据泄漏

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib_db.sh"
source "$ROOT_DIR/scripts/lib_git.sh"

echo "=========================================="
echo "  Test Cluster Cleanup Tool"
echo "=========================================="
echo ""

# 统计
total_cleaned=0
k8s_cleaned=0
argocd_cleaned=0
db_cleaned=0
git_cleaned=0

# 1. 清理 K8s 集群
echo "[1/4] Cleaning K8s test clusters..."
echo "  Looking for clusters: test-*, rttr-*"

# k3d 集群
k3d_test_clusters=$(k3d cluster list 2>/dev/null | grep -E "^(test-|rttr-)" | awk '{print $1}' || echo "")
if [ -n "$k3d_test_clusters" ]; then
  echo "  Found k3d test clusters:"
  echo "$k3d_test_clusters" | sed 's/^/    - /'
  for cluster in $k3d_test_clusters; do
    echo "  Deleting k3d cluster: $cluster"
    k3d cluster delete "$cluster" 2>/dev/null || echo "    ⚠ Failed to delete $cluster"
    k8s_cleaned=$((k8s_cleaned + 1))
  done
else
  echo "  ✓ No k3d test clusters found"
fi

# kind 集群
kind_test_clusters=$(kind get clusters 2>/dev/null | grep -E "^(test-|rttr-)" || echo "")
if [ -n "$kind_test_clusters" ]; then
  echo "  Found kind test clusters:"
  echo "$kind_test_clusters" | sed 's/^/    - /'
  for cluster in $kind_test_clusters; do
    echo "  Deleting kind cluster: $cluster"
    kind delete cluster --name "$cluster" 2>/dev/null || echo "    ⚠ Failed to delete $cluster"
    k8s_cleaned=$((k8s_cleaned + 1))
  done
else
  echo "  ✓ No kind test clusters found"
fi

echo "  Summary: Cleaned $k8s_cleaned K8s clusters"
echo ""

# 2. 清理 ArgoCD secrets
echo "[2/4] Cleaning ArgoCD cluster secrets..."
if kubectl --context k3d-devops get namespace argocd >/dev/null 2>&1; then
  argocd_secrets=$(kubectl --context k3d-devops get secrets -n argocd \
    -l "argocd.argoproj.io/secret-type=cluster" --no-headers 2>/dev/null | \
    awk '{print $1}' | grep -E "(test-|rttr-)" || echo "")
  
  if [ -n "$argocd_secrets" ]; then
    echo "  Found ArgoCD test secrets:"
    echo "$argocd_secrets" | sed 's/^/    - /'
    for secret in $argocd_secrets; do
      echo "  Deleting secret: $secret"
      kubectl --context k3d-devops delete secret "$secret" -n argocd 2>/dev/null || echo "    ⚠ Failed to delete $secret"
      argocd_cleaned=$((argocd_cleaned + 1))
    done
  else
    echo "  ✓ No ArgoCD test secrets found"
  fi
else
  echo "  ⚠ ArgoCD namespace not accessible, skipping"
fi

echo "  Summary: Cleaned $argocd_cleaned ArgoCD secrets"
echo ""

# 3. 清理数据库记录
echo "[3/4] Cleaning database records..."
if db_is_available 2>/dev/null; then
  # 查询测试集群记录
  db_test_clusters=$(db_query "SELECT name FROM clusters WHERE name LIKE 'test-%' OR name LIKE 'rttr-%';" 2>/dev/null | grep -E "^(test-|rttr-)" || echo "")
  
  if [ -n "$db_test_clusters" ]; then
    echo "  Found database test records:"
    echo "$db_test_clusters" | sed 's/^/    - /'
    
    # 执行删除
    deleted_count=$(db_query "DELETE FROM clusters WHERE name LIKE 'test-%' OR name LIKE 'rttr-%' RETURNING name;" 2>/dev/null | grep -cE "^(test-|rttr-)" || echo "0")
    db_cleaned=$deleted_count
    echo "  ✓ Deleted $db_cleaned database records"
  else
    echo "  ✓ No database test records found"
  fi
else
  echo "  ⚠ Database not accessible, skipping"
fi

echo "  Summary: Cleaned $db_cleaned database records"
echo ""

# 4. 清理 Git 分支
echo "[4/4] Cleaning Git branches..."
if git_is_available 2>/dev/null; then
  # 获取所有测试分支
  test_branches=$(git_list_branches 2>/dev/null | grep -E "^(test-|rttr-)" || echo "")
  
  if [ -n "$test_branches" ]; then
    echo "  Found Git test branches:"
    echo "$test_branches" | sed 's/^/    - /'
    
    for branch in $test_branches; do
      echo "  Deleting branch: $branch"
      if git_delete_branch "$branch" 2>/dev/null; then
        git_cleaned=$((git_cleaned + 1))
      else
        echo "    ⚠ Failed to delete branch $branch"
      fi
    done
  else
    echo "  ✓ No Git test branches found"
  fi
else
  echo "  ⚠ Git service not accessible, skipping"
fi

echo "  Summary: Cleaned $git_cleaned Git branches"
echo ""

# 5. 清理 Portainer endpoints
portainer_cleaned=0
echo "[5/5] Cleaning Portainer endpoints..."
if [ -f "$ROOT_DIR/config/secrets.env" ]; then
  source "$ROOT_DIR/config/secrets.env"
  PORTAINER_URL="https://portainer.devops.192.168.51.30.sslip.io"
  
  # 获取 Portainer token
  TOKEN=$(curl -s -k -X POST "$PORTAINER_URL/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$PORTAINER_ADMIN_PASSWORD\"}" \
    2>/dev/null | jq -r '.jwt' 2>/dev/null || echo "")
  
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    # 获取所有 endpoints
    endpoints=$(curl -s -k -H "Authorization: Bearer $TOKEN" \
      "$PORTAINER_URL/api/endpoints" 2>/dev/null)
    
    if [ -n "$endpoints" ]; then
      # 过滤测试 endpoints (名称包含 test- 或 rttr-)
      test_endpoints=$(echo "$endpoints" | jq -r '.[] | select(.Name | test("test|rttr"; "i")) | "\(.Id):\(.Name)"' 2>/dev/null || echo "")
      
      if [ -n "$test_endpoints" ]; then
        echo "  Found Portainer test endpoints:"
        echo "$test_endpoints" | sed 's/^/    - /'
        
        echo "$test_endpoints" | while IFS=: read -r id name; do
          if [ -n "$id" ] && [ -n "$name" ]; then
            echo "  Deleting endpoint: $name (ID: $id)"
            if curl -s -k -X DELETE \
              -H "Authorization: Bearer $TOKEN" \
              "$PORTAINER_URL/api/endpoints/$id" >/dev/null 2>&1; then
              portainer_cleaned=$((portainer_cleaned + 1))
            else
              echo "    ⚠ Failed to delete $name"
            fi
          fi
        done
        
        # 重新计数（因为 while 循环在子shell中）
        portainer_cleaned=$(echo "$test_endpoints" | wc -l)
      else
        echo "  ✓ No Portainer test endpoints found"
      fi
    else
      echo "  ⚠ Failed to get endpoints from Portainer"
    fi
  else
    echo "  ⚠ Portainer not accessible or authentication failed, skipping"
  fi
else
  echo "  ⚠ secrets.env not found, skipping Portainer cleanup"
fi

echo "  Summary: Cleaned $portainer_cleaned Portainer endpoints"
echo ""

# 总结
total_cleaned=$((k8s_cleaned + argocd_cleaned + db_cleaned + git_cleaned + portainer_cleaned))
echo "=========================================="
echo "  Cleanup Summary"
echo "=========================================="
echo "K8s clusters:        $k8s_cleaned"
echo "ArgoCD secrets:      $argocd_cleaned"
echo "DB records:          $db_cleaned"
echo "Git branches:        $git_cleaned"
echo "Portainer endpoints: $portainer_cleaned"
echo "----------------------------------------"
echo "Total cleaned:       $total_cleaned"
echo ""

if [ $total_cleaned -eq 0 ]; then
  echo "✓ No test resources found, system is clean"
else
  echo "✓ Cleanup completed successfully"
fi

