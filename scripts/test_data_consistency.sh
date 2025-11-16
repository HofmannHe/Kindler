#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Description: Full data consistency sweep across SQLite, clusters, ApplicationSet, Portainer, and ArgoCD.
# Usage: scripts/test_data_consistency.sh [--json-summary]
# Category: diagnostics
# Status: stable
# See also: scripts/db_verify.sh, scripts/check_consistency.sh

# 完整的数据一致性测试脚本
# 验证数据库、集群、ApplicationSet、Portainer、ArgoCD 的一致性

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/lib/lib_sqlite.sh"

usage() {
  cat << 'USAGE'
Usage: scripts/test_data_consistency.sh [--json-summary]

Options:
  --json-summary   Emit machine-readable summary (CONSISTENCY_SUMMARY=...)
  -h, --help       Show this help message
USAGE
}

json_summary=false
while [ $# -gt 0 ]; do
  case "$1" in
    --json-summary)
      json_summary=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "=========================================="
echo "  数据一致性完整测试"
echo "=========================================="
echo ""

PASSED=0
FAILED=0
declare -a JSON_CHECKS=()

# 从 environments.csv 读取预置业务集群（排除 devops），用于确定“必须出现在 Portainer/ArgoCD/HAProxy 中”的核心业务集群集合
EXPECTED_CLUSTERS=""
EXPECTED_HAPROXY_CLUSTERS=""
if [ -f "$ROOT_DIR/config/environments.csv" ]; then
  EXPECTED_CLUSTERS=$(awk -F, '
    NR>1 && $0 !~ /^[[:space:]]*#/ && NF>=5 {
      env=$1; provider=$2; reg_portainer=$5;
      gsub(/[[:space:]]+/, "", env);
      gsub(/[[:space:]]+/, "", provider);
      gsub(/[[:space:]]+/, "", reg_portainer);
      if (env != "" && env != "devops" && reg_portainer != "" && tolower(reg_portainer) != "false" && tolower(reg_portainer) != "0") {
        print env "|" provider;
      }
    }' "$ROOT_DIR/config/environments.csv" || echo "")
  EXPECTED_HAPROXY_CLUSTERS=$(awk -F, '
    NR>1 && $0 !~ /^[[:space:]]*#/ && NF>=6 {
      env=$1; provider=$2; haproxy_route=$6;
      gsub(/[[:space:]]+/, "", env);
      gsub(/[[:space:]]+/, "", provider);
      gsub(/[[:space:]]+/, "", haproxy_route);
      # 仅当 haproxy_route 显式为 true/on/1 时才作为“必须存在路由”的核心集群
      if (env != "" && env != "devops" && haproxy_route != "" && tolower(haproxy_route) != "false" && tolower(haproxy_route) != "0") {
        print env "|" provider;
      }
    }' "$ROOT_DIR/config/environments.csv" || echo "")
fi

# 测试函数
test_check() {
  local name="$1"
  local result="$2"

  if [ "$result" -eq 0 ]; then
    echo "  ✓ $name"
    PASSED=$((PASSED + 1))
    JSON_CHECKS+=("$name|passed")
  else
    echo "  ✗ $name"
    FAILED=$((FAILED + 1))
    JSON_CHECKS+=("$name|failed")
  fi
}

# 1. 验证数据库可用性
echo "[测试 1] 数据库可用性"
if sqlite_is_available 2> /dev/null; then
  test_check "SQLite 数据库可用" 0
else
  test_check "SQLite 数据库可用" 1
fi
echo ""

# 2. 验证数据库与集群一致性
echo "[测试 2] 数据库与集群一致性"
echo "  检查数据库记录..."

db_clusters=$(sqlite_query "SELECT name, provider FROM clusters WHERE name != 'devops' ORDER BY name;" 2> /dev/null || echo "")
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
  if kubectl --context "$ctx" get nodes > /dev/null 2>&1; then
    echo "    ✓ $name ($provider) - 数据库记录存在且集群存在"
    match_count=$((match_count + 1))
  else
    echo "    ✗ $name ($provider) - 数据库记录存在但集群不存在"
    FAILED=$((FAILED + 1))
  fi
done < <(echo "$db_clusters")

if [ "$db_count" -eq 0 ]; then
  echo "    ℹ 数据库中没有业务集群记录"
fi

if [ "$db_count" -eq "$match_count" ] && [ "$db_count" -gt 0 ]; then
  test_check "数据库与集群一致 ($match_count/$db_count)" 0
else
  test_check "数据库与集群一致 ($match_count/$db_count)" 1
fi
echo ""

# 3. 验证 ApplicationSet 准确性
echo "[测试 3] ApplicationSet 准确性"
echo "  同步 ApplicationSet..."

if [ -f "$ROOT_DIR/scripts/sync_applicationset.sh" ]; then
  if "$ROOT_DIR/scripts/sync_applicationset.sh" > /tmp/applicationset_sync.log 2>&1; then
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
        provider=$(sqlite_query "SELECT provider FROM clusters WHERE name = '$cluster';" 2> /dev/null | head -1 | tr -d ' \n' || echo "")
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

        if kubectl --context "$ctx" get nodes > /dev/null 2>&1; then
          echo "    ✓ $cluster - ApplicationSet 中存在且集群存在"
          appset_valid=$((appset_valid + 1))
        else
          echo "    ✗ $cluster - ApplicationSet 中存在但集群不存在"
          FAILED=$((FAILED + 1))
        fi
      done

      if [ "$appset_count" -eq "$appset_valid" ] && [ "$appset_count" -gt 0 ]; then
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
if kubectl --context k3d-devops get ns argocd > /dev/null 2>&1; then
  argocd_apps=$(kubectl --context k3d-devops get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2> /dev/null || echo "")
  argocd_count=$(echo "$argocd_apps" | wc -w || echo "0")

  if [ "$argocd_count" -gt 0 ]; then
    echo "    ArgoCD 中有 $argocd_count 个 Applications"

    # 验证每个 Application 对应的集群是否存在
    for app in $argocd_apps; do
      cluster=$(kubectl --context k3d-devops get application "$app" -n argocd -o jsonpath='{.spec.destination.name}' 2> /dev/null || echo "")
      if [ -n "$cluster" ]; then
        # 尝试找到对应的 context
        ctx=""
        for existing_ctx in $(kubectl config get-contexts -o name 2> /dev/null | grep -E "k3d-|kind-" || true); do
          if echo "$existing_ctx" | grep -q "$cluster"; then
            ctx="$existing_ctx"
            break
          fi
        done

        if [ -n "$ctx" ] && kubectl --context "$ctx" get nodes > /dev/null 2>&1; then
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

  # 核心业务集群的 whoami Application 覆盖检查
  if [ -n "$EXPECTED_CLUSTERS" ] && [ "$argocd_count" -gt 0 ]; then
    apps_json=$(kubectl --context k3d-devops -n argocd get applications -o json 2> /dev/null || echo "")
    if ! echo "$apps_json" | jq -e '.items | type == "array"' >/dev/null 2>&1; then
      echo "    ✗ 无法获取 ArgoCD applications 详细列表"
      test_check "ArgoCD whoami 应用覆盖核心业务集群" 1
    else
      missing_apps=0
      while IFS='|' read -r env_name env_provider; do
        [ -z "$env_name" ] && continue
        app_name="whoami-${env_name}"
        if echo "$apps_json" | jq -e --arg n "$app_name" '.items[] | select(.metadata.name == $n)' >/dev/null 2>&1; then
          echo "    ✓ $app_name: 存在于 ArgoCD"
        else
          echo "    ✗ $app_name: 在 ArgoCD 中缺失"
          missing_apps=$((missing_apps + 1))
        fi
      done <<< "$EXPECTED_CLUSTERS"

      if [ "$missing_apps" -eq 0 ]; then
        test_check "ArgoCD whoami 应用覆盖核心业务集群" 0
      else
        test_check "ArgoCD whoami 应用覆盖核心业务集群" 1
      fi
    fi
  fi
else
  echo "    ⚠ ArgoCD namespace 不存在"
  test_check "ArgoCD 可访问" 1
fi
echo ""

# 5. 验证 Portainer 端点与核心业务集群一致性
echo "[测试 5] Portainer 端点一致性"

if [ -z "$EXPECTED_CLUSTERS" ]; then
  echo "  ⚠ environments.csv 中没有需要强制校验的业务集群，跳过 Portainer 端点检查"
  test_check "Portainer 端点与核心业务集群一致" 0
else
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^portainer-ce$'; then
    echo "  ✗ Portainer 容器未运行，无法检查端点"
    test_check "Portainer 端点与核心业务集群一致" 1
  else
    # 加载 Portainer 管理员密码
    if [ -f "$ROOT_DIR/config/secrets.env" ]; then
      # shellcheck disable=SC1090
      . "$ROOT_DIR/config/secrets.env"
    fi
    : "${PORTAINER_ADMIN_PASSWORD:=admin123}"

    # 直接通过容器 IP 访问 Portainer，避免依赖 HAProxy
    PORTAINER_HTTP_PORT="${PORTAINER_HTTP_PORT:-9000}"
    PORTAINER_IP=$(docker inspect portainer-ce --format '{{with index .NetworkSettings.Networks "infrastructure"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)
    if [ -z "$PORTAINER_IP" ]; then
      PORTAINER_IP=$(docker inspect portainer-ce --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
    fi

    if [ -z "$PORTAINER_IP" ]; then
      echo "  ✗ 无法解析 Portainer 容器 IP"
      test_check "Portainer 端点与核心业务集群一致" 1
    else
      PORTAINER_URL="http://${PORTAINER_IP}:${PORTAINER_HTTP_PORT}"
      echo "  Portainer API: $PORTAINER_URL"

      # 获取 JWT
      jwt=""
      for i in 1 2 3 4 5; do
        jwt=$(curl -sk -m 8 -X POST "$PORTAINER_URL/api/auth" \
          -H "Content-Type: application/json" \
          -d "{\"username\": \"admin\", \"password\": \"${PORTAINER_ADMIN_PASSWORD}\"}" 2>/dev/null | jq -r '.jwt // empty' || true)
        [ -n "$jwt" ] && [ "$jwt" != "null" ] && break
        sleep $((i * 2))
      done

      if [ -z "$jwt" ] || [ "$jwt" = "null" ]; then
        echo "  ✗ 无法使用 config/secrets.env 中的密码登录 Portainer"
        test_check "Portainer 端点与核心业务集群一致" 1
      else
        endpoints_json=$(curl -sk -m 10 -X GET "$PORTAINER_URL/api/endpoints" \
          -H "Authorization: Bearer $jwt" 2>/dev/null || echo "[]")

        if ! echo "$endpoints_json" | jq -e '. | type == "array"' >/dev/null 2>&1; then
          echo "  ✗ 无法解析 Portainer /api/endpoints 返回结果"
          test_check "Portainer 端点与核心业务集群一致" 1
        else
          endpoint_names=$(echo "$endpoints_json" | jq -r '.[].Name' 2>/dev/null | sort || echo "")
          echo "  Portainer endpoints:"
          echo "$endpoint_names" | sed 's/^/    - /'

          missing=0
          while IFS='|' read -r env_name env_provider; do
            [ -z "$env_name" ] && continue
            if echo "$endpoint_names" | grep -qx "$env_name"; then
              echo "    ✓ $env_name: endpoint 存在"
            else
              echo "    ✗ $env_name: 在 Portainer endpoints 中缺失"
              missing=$((missing + 1))
            fi
          done <<< "$EXPECTED_CLUSTERS"

          if [ "$missing" -eq 0 ]; then
            test_check "Portainer 端点与核心业务集群一致" 0
          else
            test_check "Portainer 端点与核心业务集群一致" 1
          fi
        fi
      fi
    fi
  fi
fi
echo ""

# 6. 验证 HAProxy 路由与核心业务集群一致性
echo "[测试 6] HAProxy 路由与核心业务集群一致性"

cfg="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
if [ -z "$EXPECTED_HAPROXY_CLUSTERS" ]; then
  echo "  ⚠ environments.csv 中没有启用 haproxy_route 的业务集群，跳过 HAProxy 路由检查"
  test_check "HAProxy 路由与核心业务集群一致" 0
else
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'haproxy-gw'; then
    echo "  ✗ haproxy-gw 容器未运行，无法检查 HAProxy 路由"
    test_check "HAProxy 路由与核心业务集群一致" 1
  else
    # 先验证 HAProxy 配置语法有效（忽略 WARNING）
    validation_output=$(docker exec haproxy-gw /usr/local/sbin/haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 2>&1 || true)
    if echo "$validation_output" | grep -q "ALERT"; then
      echo "  ✗ HAProxy 配置校验失败"
      echo "$validation_output" | grep -E "(ALERT|ERROR)" | head -5 | sed 's/^/    /'
      test_check "HAProxy 路由与核心业务集群一致" 1
    else
      echo "  ✓ HAProxy 配置校验通过（忽略 WARNING）"
      if [ ! -f "$cfg" ]; then
        echo "  ✗ 找不到 haproxy.cfg: $cfg"
        test_check "HAProxy 路由与核心业务集群一致" 1
      else
        missing=0
        while IFS='|' read -r env_name env_provider; do
          [ -z "$env_name" ] && continue
          # 检查动态 ACL / use_backend / backend 是否齐全
          if ! grep -q "acl host_${env_name} " "$cfg"; then
            echo "    ✗ $env_name: 缺少动态 ACL host_${env_name}"
            missing=$((missing + 1))
            continue
          fi
          if ! grep -q "use_backend be_${env_name} if host_${env_name}" "$cfg"; then
            echo "    ✗ $env_name: 缺少 use_backend be_${env_name} if host_${env_name}"
            missing=$((missing + 1))
            continue
          fi
          if ! grep -q "backend be_${env_name}" "$cfg"; then
            echo "    ✗ $env_name: 缺少 backend be_${env_name}"
            missing=$((missing + 1))
            continue
          fi
          echo "    ✓ $env_name: ACL/use_backend/backend 均存在"
        done <<< "$EXPECTED_HAPROXY_CLUSTERS"

        if [ "$missing" -eq 0 ]; then
          test_check "HAProxy 路由与核心业务集群一致" 0
        else
          test_check "HAProxy 路由与核心业务集群一致" 1
        fi
      fi
    fi
  fi
fi
echo ""

# 7. 验证幂等性
echo "[测试 7] 幂等性测试"
echo "  多次运行 cleanup_nonexistent_clusters.sh..."

if [ -f "$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" ]; then
  # 第一次运行
  result1=$("$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" 2>&1 | tail -1)
  # 第二次运行
  result2=$("$ROOT_DIR/scripts/cleanup_nonexistent_clusters.sh" 2>&1 | tail -1)

  if [ "$result1" = "$result2" ]; then
    test_check "cleanup_nonexistent_clusters.sh 幂等性" 0
  else
    test_check "cleanup_nonexistent_clusters.sh 幂等性" 1
    echo "    第一次: $result1"
    echo "    第二次: $result2"
  fi
else
  echo "  ⚠ cleanup_nonexistent_clusters.sh 不存在，跳过"
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
else
  echo "=========================================="
  echo "✗ 有 $FAILED 个测试失败"
  echo "=========================================="
fi

if $json_summary; then
  if command -v python3 > /dev/null 2>&1; then
    summary_payload=$(printf '%s\n' "${JSON_CHECKS[@]}")
    summary=$(
      CONSISTENCY_ROWS="$summary_payload" python3 - << 'PY'
import json, os
rows = [line.strip() for line in os.environ.get("CONSISTENCY_ROWS", "").splitlines() if line.strip()]
items = []
for row in rows:
    name, status = row.split('|', 1)
    items.append({"name": name, "status": status})
summary = {
    "passed": len([i for i in items if i["status"] == "passed"]),
    "failed": len([i for i in items if i["status"] == "failed"]),
    "checks": items,
}
print(json.dumps(summary, ensure_ascii=False))
PY
    )
    echo "CONSISTENCY_SUMMARY=${summary}"
  else
    echo "CONSISTENCY_SUMMARY={\"passed\":$PASSED,\"failed\":$FAILED}"
  fi
fi

if [ $FAILED -eq 0 ]; then
  exit 0
else
  exit 1
fi
