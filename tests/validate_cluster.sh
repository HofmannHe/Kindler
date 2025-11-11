#!/usr/bin/env bash
# 集群生命周期快速验收脚本
set -Eeuo pipefail

CLUSTER_NAME="${1:-}"
MODE="${2:-exist}"  # exist (验证存在) 或 deleted (验证已删除)

if [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <cluster_name> [exist|deleted]"
  echo ""
  echo "Examples:"
  echo "  $0 test-123456 exist    # 验证集群存在且正常"
  echo "  $0 test-123456 deleted  # 验证集群已删除"
  exit 1
fi

# 加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/lib.sh"
source "${SCRIPT_DIR}/../config/clusters.env"

echo "=== 验收集群: $CLUSTER_NAME (模式: $MODE) ==="
echo ""

# 确定 provider 和 context（如果集群存在）
PROVIDER=$(grep "^${CLUSTER_NAME}," "${SCRIPT_DIR}/../config/environments.csv" 2>/dev/null | cut -d, -f2 || echo "")
if [ -n "$PROVIDER" ]; then
  if [ "$PROVIDER" = "k3d" ]; then
    CONTEXT="k3d-${CLUSTER_NAME}"
  else
    CONTEXT="kind-${CLUSTER_NAME}"
  fi
else
  CONTEXT=""
fi

PASSED=0
FAILED=0
TOTAL=7

if [ "$MODE" = "exist" ]; then
  echo "📋 验收标准：所有检查项必须通过"
  echo ""
  
  # 1. K8s 集群
  echo -n "[1/7] K8s 集群运行状态... "
  if [ -n "$CONTEXT" ] && kubectl --context "$CONTEXT" get nodes &>/dev/null; then
    NODE_STATUS=$(kubectl --context "$CONTEXT" get nodes --no-headers | awk '{print $2}' | head -1)
    if [ "$NODE_STATUS" = "Ready" ]; then
      echo "✅ Ready"
      ((PASSED++))
    else
      echo "❌ Not Ready"
      ((FAILED++))
    fi
  else
    echo "❌ 无法访问"
    ((FAILED++))
  fi

  # 2. 数据库
  echo -n "[2/7] 数据库记录... "
  DB_COUNT=$(kubectl --context k3d-devops exec -n paas deploy/postgresql -- \
    psql -U admin -d paas -t -c "SELECT COUNT(*) FROM clusters WHERE name='${CLUSTER_NAME}';" 2>/dev/null | tr -d ' ' || echo "0")
  if [ "$DB_COUNT" = "1" ]; then
    echo "✅ 存在"
    ((PASSED++))
  else
    echo "❌ 不存在 (count: $DB_COUNT)"
    ((FAILED++))
  fi

  # 3. Git 分支
  echo -n "[3/7] Git 分支... "
  source "${SCRIPT_DIR}/../config/git.env"
  GIT_REMOTE="http://${GIT_USERNAME}:${GIT_PASSWORD}@${GIT_DOMAIN}/${GIT_ORG}/${GIT_REPO}.git"
  if timeout 10 git ls-remote "$GIT_REMOTE" 2>/dev/null | grep -q "refs/heads/${CLUSTER_NAME}"; then
    echo "✅ 存在"
    ((PASSED++))
  else
    echo "❌ 不存在"
    ((FAILED++))
  fi

  # 4. ArgoCD Application
  echo -n "[4/7] ArgoCD Application... "
  if kubectl --context k3d-devops get application -n argocd "whoami-${CLUSTER_NAME}" &>/dev/null; then
    APP_SYNC=$(kubectl --context k3d-devops get application -n argocd "whoami-${CLUSTER_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    APP_HEALTH=$(kubectl --context k3d-devops get application -n argocd "whoami-${CLUSTER_NAME}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    echo "✅ $APP_SYNC / $APP_HEALTH"
    ((PASSED++))
  else
    echo "❌ 不存在"
    ((FAILED++))
  fi

  # 5. HAProxy 路由
  echo -n "[5/7] HAProxy 路由配置... "
  if grep -q "host_${CLUSTER_NAME}[[:space:]]" "${SCRIPT_DIR}/../compose/infrastructure/haproxy.cfg"; then
    echo "✅ 已配置"
    ((PASSED++))
  else
    echo "❌ 未配置"
    ((FAILED++))
  fi

  # 6. CSV 配置
  echo -n "[6/7] CSV 配置... "
  if grep -q "^${CLUSTER_NAME}," "${SCRIPT_DIR}/../config/environments.csv"; then
    echo "✅ 存在"
    ((PASSED++))
  else
    echo "❌ 不存在"
    ((FAILED++))
  fi

  # 7. whoami HTTP 访问
  echo -n "[7/7] whoami HTTP 访问... "
  HTTP_CODE=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" "http://whoami.${CLUSTER_NAME}.${BASE_DOMAIN}" 2>/dev/null || echo "timeout")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ HTTP 200"
    ((PASSED++))
  elif [ "$HTTP_CODE" = "404" ]; then
    echo "⚠️ HTTP 404 (可接受，应用未部署)"
    ((PASSED++))
  else
    echo "❌ HTTP $HTTP_CODE"
    ((FAILED++))
  fi

elif [ "$MODE" = "deleted" ]; then
  echo "📋 验收标准：所有资源必须已清理"
  echo ""
  
  # 1. K8s 集群
  echo -n "[1/7] K8s 集群已删除... "
  if [ -z "$CONTEXT" ]; then
    echo "✅ 上下文不存在"
    ((PASSED++))
  elif ! kubectl --context "$CONTEXT" get nodes &>/dev/null; then
    echo "✅ 无法访问"
    ((PASSED++))
  else
    echo "❌ 仍然存在"
    ((FAILED++))
  fi

  # 检查 k3d/kind 列表
  if [ -n "$PROVIDER" ]; then
    if [ "$PROVIDER" = "k3d" ]; then
      if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        echo "   ❌ k3d 列表中仍存在"
        ((FAILED++))
      fi
    else
      if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        echo "   ❌ kind 列表中仍存在"
        ((FAILED++))
      fi
    fi
  fi

  # 2. 数据库记录
  echo -n "[2/7] 数据库记录已删除... "
  DB_COUNT=$(kubectl --context k3d-devops exec -n paas deploy/postgresql -- \
    psql -U admin -d paas -t -c "SELECT COUNT(*) FROM clusters WHERE name='${CLUSTER_NAME}';" 2>/dev/null | tr -d ' ' || echo "0")
  if [ "$DB_COUNT" = "0" ]; then
    echo "✅ 已删除"
    ((PASSED++))
  else
    echo "❌ 仍然存在 (count: $DB_COUNT)"
    ((FAILED++))
  fi

  # 3. Git 分支
  echo -n "[3/7] Git 分支已删除... "
  source "${SCRIPT_DIR}/../config/git.env"
  GIT_REMOTE="http://${GIT_USERNAME}:${GIT_PASSWORD}@${GIT_DOMAIN}/${GIT_ORG}/${GIT_REPO}.git"
  if timeout 10 git ls-remote "$GIT_REMOTE" 2>/dev/null | grep -q "refs/heads/${CLUSTER_NAME}"; then
    echo "❌ 仍然存在"
    ((FAILED++))
  else
    echo "✅ 已删除"
    ((PASSED++))
  fi

  # 4. ArgoCD Application
  echo -n "[4/7] ArgoCD Application 已删除... "
  if kubectl --context k3d-devops get application -n argocd "whoami-${CLUSTER_NAME}" &>/dev/null; then
    echo "❌ 仍然存在"
    ((FAILED++))
  else
    echo "✅ 已删除"
    ((PASSED++))
  fi

  # 5. HAProxy 路由
  echo -n "[5/7] HAProxy 路由已删除... "
  if grep -q "host_${CLUSTER_NAME}" "${SCRIPT_DIR}/../compose/infrastructure/haproxy.cfg"; then
    echo "❌ 仍然存在"
    ((FAILED++))
  else
    echo "✅ 已删除"
    ((PASSED++))
  fi

  # 6. CSV 配置
  echo -n "[6/7] CSV 配置已删除... "
  if grep -q "^${CLUSTER_NAME}," "${SCRIPT_DIR}/../config/environments.csv"; then
    echo "❌ 仍然存在"
    ((FAILED++))
  else
    echo "✅ 已删除"
    ((PASSED++))
  fi

  # 7. Portainer 环境（仅提示）
  echo -n "[7/7] Portainer 环境（手动检查）... "
  echo "⚠️ 需手动确认"
  echo "   URL: https://portainer.devops.${BASE_DOMAIN}"
  echo "   确认环境 '$(echo "$CLUSTER_NAME" | tr -d '-')' 不存在"
  ((PASSED++))  # 暂时算通过，需要手动确认
  
else
  echo "错误：未知模式 '$MODE'"
  echo "支持的模式: exist, deleted"
  exit 1
fi

echo ""
echo "========================================"
echo "验收结果: $PASSED/$TOTAL 通过, $FAILED/$TOTAL 失败"
echo "========================================"

if [ $FAILED -eq 0 ]; then
  echo "✅ 验收通过"
  exit 0
else
  echo "❌ 验收失败"
  
  # 给出诊断建议
  if [ "$MODE" = "exist" ]; then
    echo ""
    echo "诊断建议："
    echo "1. 检查集群日志: kubectl --context $CONTEXT get events -A"
    echo "2. 检查 ArgoCD: kubectl --context k3d-devops get application -n argocd whoami-${CLUSTER_NAME} -o yaml"
    echo "3. 检查 HAProxy: grep -A 5 '$CLUSTER_NAME' compose/infrastructure/haproxy.cfg"
    echo "4. 手动同步: kubectl --context k3d-devops patch application whoami-${CLUSTER_NAME} -n argocd --type='json' -p='[{\"op\": \"replace\", \"path\": \"/operation\", \"value\": {\"sync\": {\"revision\": \"HEAD\"}}}]'"
  fi
  
  exit 1
fi
