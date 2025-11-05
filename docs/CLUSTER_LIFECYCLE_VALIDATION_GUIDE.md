# 集群生命周期验收指引

**目的**: 验证集群创建、运行、删除全生命周期的完整性和一致性

---

## 第一步：添加测试集群

### 1.1 创建集群

选择一个测试集群名称（建议使用时间戳避免冲突）：

```bash
# 推荐使用时间戳命名
TEST_CLUSTER="test-$(date +%s)"
echo "测试集群名称: $TEST_CLUSTER"

# 创建 k3d 集群（推荐，更快）
scripts/create_env.sh -n $TEST_CLUSTER -p k3d

# 或创建 kind 集群
# scripts/create_env.sh -n $TEST_CLUSTER -p kind
```

**预期输出**：
```
[CREATE] Creating new cluster: test-1738158
[CREATE] Provider: k3d
[CREATE] Checking if cluster already exists...
[CREATE] Cluster does not exist, proceeding with creation...
[CREATE] ✓ Cluster configuration saved to database
[CREATE] ✓ Cluster configuration saved to CSV
[CREATE] Creating k3d cluster test-1738158...
[CREATE] ✓ k3d cluster test-1738158 created successfully
[CREATE] ✓ Git branch created: test-1738158
[CREATE] ✓ ArgoCD Application synced: whoami-test-1738158
[CREATE] ✓ Portainer Edge Environment registered: test1738158
[CREATE] ✓ HAProxy route added for test-1738158
[SUCCESS] Cluster test-1738158 created successfully
```

### 1.2 等待集群就绪

```bash
# 等待 60 秒让 ArgoCD 同步和 whoami 部署
echo "等待集群和应用就绪（60秒）..."
sleep 60
```

---

## 第二步：全方位验收

### 2.1 Kubernetes 集群验收

```bash
echo "=== [1/7] K8s 集群状态 ==="

# 确定 provider 和 context
PROVIDER=$(grep "^${TEST_CLUSTER}," config/environments.csv | cut -d, -f2)
if [ "$PROVIDER" = "k3d" ]; then
  CONTEXT="k3d-${TEST_CLUSTER}"
else
  CONTEXT="kind-${TEST_CLUSTER}"
fi

echo "Provider: $PROVIDER"
echo "Context: $CONTEXT"

# 检查节点状态
kubectl --context "$CONTEXT" get nodes
# 预期：所有节点 STATUS=Ready

# 检查系统 Pod
kubectl --context "$CONTEXT" get pods -A | grep -E "(coredns|traefik|ingress-nginx)"
# 预期：coredns, traefik(k3d) 或 ingress-nginx(kind) 都是 Running
```

**验收标准**：
- ✅ 节点状态: Ready
- ✅ coredns: Running
- ✅ Ingress Controller: Running (Traefik for k3d, ingress-nginx for kind)

---

### 2.2 数据库记录验收

```bash
echo "=== [2/7] 数据库记录 ==="

# 连接到 PostgreSQL 查询
kubectl --context k3d-devops exec -n paas deploy/postgresql -- \
  psql -U admin -d paas -c \
  "SELECT name, provider, node_port, http_port, https_port, subnet FROM clusters WHERE name='${TEST_CLUSTER}';"

# 或使用 list_env.sh
scripts/list_env.sh | grep "$TEST_CLUSTER"
```

**验收标准**：
- ✅ 记录存在
- ✅ provider 正确（k3d 或 kind）
- ✅ 端口配置正确（http_port, https_port）
- ✅ subnet 配置正确（k3d 有子网，kind 为 NULL）

**示例输出**：
```
    name     | provider | node_port | http_port | https_port |     subnet
-------------+----------+-----------+-----------+------------+----------------
 test-123456 | k3d      |     30080 |     18096 |      18449 | 10.104.0.0/16
```

---

### 2.3 Git 分支验收

```bash
echo "=== [3/7] Git 分支状态 ==="

# 检查分支是否存在
source config/git.env
GIT_REMOTE="http://${GIT_USERNAME}:${GIT_PASSWORD}@${GIT_DOMAIN}/${GIT_ORG}/${GIT_REPO}.git"

git ls-remote $GIT_REMOTE | grep "refs/heads/${TEST_CLUSTER}"

# 或通过 HTTP 检查
curl -s "http://git.devops.192.168.51.30.sslip.io/fc005/devops/branches" | grep -o "$TEST_CLUSTER"
```

**验收标准**：
- ✅ 分支存在于远程仓库
- ✅ 分支包含 whoami 应用配置（deploy/ 目录）

---

### 2.4 Portainer 注册验收

```bash
echo "=== [4/7] Portainer Edge Agent 状态 ==="

# 检查 Edge Agent Pod
kubectl --context "$CONTEXT" get pods -n portainer
# 预期：edge-agent Pod Running

# 通过 API 检查（需要 Portainer API token）
# 或直接访问 Portainer UI：
echo "请访问 https://portainer.devops.192.168.51.30.sslip.io"
echo "在 Environments 页面查找: ${TEST_CLUSTER}"
echo "状态应为: online (绿色)"
```

**验收标准**：
- ✅ edge-agent Pod 状态: Running
- ✅ Portainer UI 显示环境名称（注意：自动去掉 - 符号，如 test-123 -> test123）
- ✅ 连接状态: online

**手动检查**：
1. 打开 https://portainer.devops.192.168.51.30.sslip.io
2. 点击左侧 "Environments"
3. 搜索集群名称（注意去掉 - 符号）
4. 确认状态为 "Connected" 或 "online"

---

### 2.5 ArgoCD Application 验收

```bash
echo "=== [5/7] ArgoCD Application 状态 ==="

# 检查 Application
kubectl --context k3d-devops get application -n argocd "whoami-${TEST_CLUSTER}" \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# 查看详细状态
kubectl --context k3d-devops get application -n argocd "whoami-${TEST_CLUSTER}" -o yaml | \
  grep -A 5 "status:"
```

**验收标准**：
- ✅ Application 存在
- ✅ Sync Status: Synced
- ✅ Health Status: Healthy 或 Progressing

**如果状态不正常**：
```bash
# 手动触发同步
kubectl --context k3d-devops patch application "whoami-${TEST_CLUSTER}" -n argocd \
  --type='json' -p='[{"op": "replace", "path": "/operation", "value": {"sync": {"revision": "HEAD"}}}]'

# 等待 30 秒后重新检查
sleep 30
kubectl --context k3d-devops get application -n argocd "whoami-${TEST_CLUSTER}"
```

---

### 2.6 HAProxy 路由验收

```bash
echo "=== [6/7] HAProxy 路由配置 ==="

# 检查 ACL 和 Backend 配置
grep -A 2 "acl host_${TEST_CLUSTER}" compose/infrastructure/haproxy.cfg
grep -A 5 "backend be_${TEST_CLUSTER}" compose/infrastructure/haproxy.cfg

# 检查预期的配置
source scripts/lib.sh
CSV_FILE="config/environments.csv"
read -r env provider node_port pf_port reg_port ha_route http_port https_port subnet < <(
  grep "^${TEST_CLUSTER}," "$CSV_FILE" | tr ',' ' '
)

echo "预期 HTTP 端口: $http_port"
echo "预期 HTTPS 端口: $https_port"
```

**验收标准**：
- ✅ ACL 定义存在（格式：`acl host_test-123 hdr_reg(host) -i \.test-123\.`）
- ✅ Backend 定义存在
- ✅ Backend 使用正确的 http_port（而非 node_port）
- ✅ use_backend 规则存在

**预期 ACL 格式**：
```haproxy
acl host_test-123 hdr_reg(host) -i \.test-123\.
use_backend be_test-123 if host_test-123
```

**预期 Backend 格式**（k3d）：
```haproxy
backend be_test-123
  server s1 127.0.0.1:18096  # 使用 http_port
```

---

### 2.7 whoami 应用 HTTP 访问验收

```bash
echo "=== [7/7] whoami 应用 HTTP 访问 ==="

# 构建域名
source config/clusters.env
DOMAIN="whoami.${TEST_CLUSTER}.${BASE_DOMAIN}"
echo "测试域名: $DOMAIN"

# 测试 HTTP 访问
HTTP_CODE=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN}" 2>/dev/null || echo "timeout")
echo "HTTP 状态码: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ]; then
  echo "✅ HTTP 访问成功"
  
  # 验证内容
  CONTENT=$(timeout 10 curl -s "http://${DOMAIN}" 2>/dev/null | head -3)
  echo "响应内容:"
  echo "$CONTENT"
  
  if echo "$CONTENT" | grep -q "Hostname:"; then
    echo "✅ 内容验证通过"
  else
    echo "❌ 内容验证失败"
  fi
elif [ "$HTTP_CODE" = "404" ]; then
  echo "⚠️ HTTP 404 - 应用未部署（Git 服务不可用时正常）"
elif [ "$HTTP_CODE" = "503" ] || [ "$HTTP_CODE" = "502" ]; then
  echo "❌ HTTP $HTTP_CODE - 路由或服务异常"
  
  # 诊断信息
  echo "诊断步骤："
  echo "1. 检查 Ingress: kubectl --context $CONTEXT get ingress -n whoami"
  echo "2. 检查 Service: kubectl --context $CONTEXT get svc -n whoami"
  echo "3. 检查 Pod: kubectl --context $CONTEXT get pods -n whoami"
else
  echo "❌ HTTP 访问失败: $HTTP_CODE"
fi

# 检查 Ingress 配置
echo ""
echo "Ingress 配置:"
kubectl --context "$CONTEXT" get ingress -n whoami whoami -o yaml | grep -A 3 "spec:"
```

**验收标准**：
- ✅ HTTP 200: 应用完全正常
- ⚠️ HTTP 404: 路由正常但应用未部署（可接受，如果 Git 服务不可用）
- ❌ HTTP 502/503: 路由或集群异常（失败）

---

## 第三步：删除集群

### 3.1 执行删除

```bash
echo "=== 删除测试集群 ==="
scripts/delete_env.sh -n $TEST_CLUSTER
```

**预期输出**：
```
[DELETE] Edge Agent from cluster test-123456
[DELETE] haproxy route for test-123456
[DELETE] Portainer Edge Environment: test123456
[DELETE] Unregistering cluster from ArgoCD...
[DELETE] Removing Git branch for test-123456...
[DELETE] Removing cluster configuration from database...
[DELETE] ✓ Cluster configuration removed from database
[DELETE] cluster test-123456 via k3d
[DONE] Deleted env test-123456 (cluster + configuration)
```

### 3.2 等待清理完成

```bash
# 等待 30 秒确保所有异步清理完成
echo "等待清理完成（30秒）..."
sleep 30
```

---

## 第四步：验收删除后的清理状态

### 4.1 K8s 集群清理验收

```bash
echo "=== [1/7] K8s 集群已删除验证 ==="

# 尝试访问集群（应该失败）
if kubectl --context "$CONTEXT" get nodes 2>/dev/null; then
  echo "❌ 集群仍然存在"
else
  echo "✅ 集群已删除"
fi

# 检查 k3d/kind 列表
if [ "$PROVIDER" = "k3d" ]; then
  if k3d cluster list | grep -q "$TEST_CLUSTER"; then
    echo "❌ k3d 集群仍在列表中"
  else
    echo "✅ k3d 集群已从列表移除"
  fi
else
  if kind get clusters | grep -q "$TEST_CLUSTER"; then
    echo "❌ kind 集群仍在列表中"
  else
    echo "✅ kind 集群已从列表移除"
  fi
fi
```

**验收标准**：
- ✅ kubectl 无法访问集群
- ✅ 集群不在 k3d/kind 列表中

---

### 4.2 数据库记录清理验收

```bash
echo "=== [2/7] 数据库记录已删除验证 ==="

DB_RECORD=$(kubectl --context k3d-devops exec -n paas deploy/postgresql -- \
  psql -U admin -d paas -t -c \
  "SELECT COUNT(*) FROM clusters WHERE name='${TEST_CLUSTER}';")

if [ "$DB_RECORD" = " 0" ] || [ "$DB_RECORD" = "0" ]; then
  echo "✅ 数据库记录已删除"
else
  echo "❌ 数据库记录仍然存在 (count: $DB_RECORD)"
fi

# 或使用 list_env.sh
if scripts/list_env.sh | grep -q "$TEST_CLUSTER"; then
  echo "❌ 环境列表仍显示该集群"
else
  echo "✅ 环境列表已清理"
fi
```

**验收标准**：
- ✅ 数据库无该集群记录
- ✅ list_env.sh 不显示该集群

---

### 4.3 Git 分支清理验收

```bash
echo "=== [3/7] Git 分支已删除验证 ==="

source config/git.env
GIT_REMOTE="http://${GIT_USERNAME}:${GIT_PASSWORD}@${GIT_DOMAIN}/${GIT_ORG}/${GIT_REPO}.git"

if git ls-remote $GIT_REMOTE | grep -q "refs/heads/${TEST_CLUSTER}"; then
  echo "❌ Git 分支仍然存在"
else
  echo "✅ Git 分支已删除"
fi
```

**验收标准**：
- ✅ Git 远程仓库不再有该分支

---

### 4.4 Portainer 清理验收

```bash
echo "=== [4/7] Portainer 环境已删除验证 ==="

echo "请手动检查 Portainer UI："
echo "https://portainer.devops.192.168.51.30.sslip.io"
echo "在 Environments 页面确认 ${TEST_CLUSTER} (或 test123456) 不存在"
echo ""
echo "预期：环境列表中不再显示该环境"
```

**验收标准**：
- ✅ Portainer UI 中无该环境

---

### 4.5 ArgoCD Application 清理验收

```bash
echo "=== [5/7] ArgoCD Application 已删除验证 ==="

if kubectl --context k3d-devops get application -n argocd "whoami-${TEST_CLUSTER}" 2>/dev/null; then
  echo "❌ ArgoCD Application 仍然存在"
else
  echo "✅ ArgoCD Application 已删除"
fi

# 检查 ApplicationSet 是否已更新
kubectl --context k3d-devops get applicationset -n argocd whoami -o yaml | \
  grep -A 2 "env: ${TEST_CLUSTER}" || echo "✅ ApplicationSet 已更新（不包含该集群）"
```

**验收标准**：
- ✅ Application 已删除
- ✅ ApplicationSet 列表不包含该集群

---

### 4.6 HAProxy 路由清理验收

```bash
echo "=== [6/7] HAProxy 路由已删除验证 ==="

if grep -q "host_${TEST_CLUSTER}" compose/infrastructure/haproxy.cfg; then
  echo "❌ HAProxy 配置仍包含该集群的路由"
  grep -A 2 "host_${TEST_CLUSTER}" compose/infrastructure/haproxy.cfg
else
  echo "✅ HAProxy 路由已删除"
fi

if grep -q "be_${TEST_CLUSTER}" compose/infrastructure/haproxy.cfg; then
  echo "❌ HAProxy 配置仍包含该集群的 backend"
else
  echo "✅ HAProxy backend 已删除"
fi
```

**验收标准**：
- ✅ ACL 定义已删除
- ✅ Backend 定义已删除
- ✅ use_backend 规则已删除

---

### 4.7 CSV 配置清理验收

```bash
echo "=== [7/7] CSV 配置已删除验证 ==="

if grep -q "^${TEST_CLUSTER}," config/environments.csv; then
  echo "❌ CSV 配置仍包含该集群"
else
  echo "✅ CSV 配置已清理"
fi
```

**验收标准**：
- ✅ environments.csv 不包含该集群记录

---

## 完整验收清单

### 添加集群后的验收（7/7 必须全部通过）

- [ ] K8s 集群：节点 Ready + 核心组件 Running
- [ ] 数据库：记录存在且配置正确
- [ ] Git 分支：分支存在于远程仓库
- [ ] Portainer：Edge Agent online
- [ ] ArgoCD：Application Synced + Healthy
- [ ] HAProxy：ACL + Backend 配置正确
- [ ] whoami：HTTP 200 + 内容验证通过

### 删除集群后的验收（7/7 必须全部通过）

- [ ] K8s 集群：已删除，无法访问
- [ ] 数据库：记录已删除
- [ ] Git 分支：分支已删除
- [ ] Portainer：环境已删除
- [ ] ArgoCD：Application 已删除
- [ ] HAProxy：路由配置已删除
- [ ] CSV：配置已清理

---

## 常见问题排查

### whoami 应用返回 503

**可能原因**：
1. Ingress Controller 未运行
2. Ingress 配置错误
3. Service/Pod 未就绪

**排查步骤**：
```bash
# 1. 检查 Ingress Controller
kubectl --context "$CONTEXT" get pods -A | grep -E "(traefik|ingress-nginx)"

# 2. 检查 Ingress 配置
kubectl --context "$CONTEXT" get ingress -n whoami whoami -o yaml

# 3. 检查 Service
kubectl --context "$CONTEXT" get svc -n whoami

# 4. 检查 Pod
kubectl --context "$CONTEXT" get pods -n whoami

# 5. 查看 Pod 日志
kubectl --context "$CONTEXT" logs -n whoami -l app=whoami
```

### Portainer 显示 offline

**可能原因**：
1. Edge Agent Pod 未运行
2. Edge Key 不匹配
3. 网络连接问题

**排查步骤**：
```bash
# 1. 检查 Edge Agent Pod
kubectl --context "$CONTEXT" get pods -n portainer

# 2. 查看 Pod 日志
kubectl --context "$CONTEXT" logs -n portainer -l app=edge-agent

# 3. 检查 Edge Key
kubectl --context "$CONTEXT" get secret -n portainer portainer-edge-key -o yaml
```

### ArgoCD Application 状态 OutOfSync

**可能原因**：
1. Git 分支不存在或内容错误
2. Helm Chart 渲染失败
3. 资源定义冲突

**排查步骤**：
```bash
# 1. 检查 Git 分支
git ls-remote $GIT_REMOTE | grep "$TEST_CLUSTER"

# 2. 查看 Application 状态
kubectl --context k3d-devops get application -n argocd "whoami-${TEST_CLUSTER}" -o yaml

# 3. 手动同步
kubectl --context k3d-devops patch application "whoami-${TEST_CLUSTER}" -n argocd \
  --type='json' -p='[{"op": "replace", "path": "/operation", "value": {"sync": {"revision": "HEAD"}}}]'
```

---

## 快速验收脚本

创建一个快速验收脚本 `scripts/validate_cluster.sh`：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

CLUSTER_NAME="${1:-}"
if [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <cluster_name>"
  exit 1
fi

echo "=== 验收集群: $CLUSTER_NAME ==="

# 加载配置
source scripts/lib.sh
source config/clusters.env

# 确定 provider 和 context
PROVIDER=$(get_cluster_provider "$CLUSTER_NAME")
if [ "$PROVIDER" = "k3d" ]; then
  CONTEXT="k3d-${CLUSTER_NAME}"
else
  CONTEXT="kind-${CLUSTER_NAME}"
fi

PASSED=0
FAILED=0

# 1. K8s 集群
echo -n "[1/7] K8s 集群... "
if kubectl --context "$CONTEXT" get nodes &>/dev/null; then
  echo "✅"
  ((PASSED++))
else
  echo "❌"
  ((FAILED++))
fi

# 2. 数据库
echo -n "[2/7] 数据库记录... "
DB_COUNT=$(kubectl --context k3d-devops exec -n paas deploy/postgresql -- \
  psql -U admin -d paas -t -c "SELECT COUNT(*) FROM clusters WHERE name='${CLUSTER_NAME}';" 2>/dev/null | tr -d ' ')
if [ "$DB_COUNT" = "1" ]; then
  echo "✅"
  ((PASSED++))
else
  echo "❌"
  ((FAILED++))
fi

# 3. Git 分支
echo -n "[3/7] Git 分支... "
source config/git.env
if git ls-remote "http://${GIT_USERNAME}:${GIT_PASSWORD}@${GIT_DOMAIN}/${GIT_ORG}/${GIT_REPO}.git" | grep -q "refs/heads/${CLUSTER_NAME}"; then
  echo "✅"
  ((PASSED++))
else
  echo "❌"
  ((FAILED++))
fi

# 4. ArgoCD
echo -n "[4/7] ArgoCD Application... "
if kubectl --context k3d-devops get application -n argocd "whoami-${CLUSTER_NAME}" &>/dev/null; then
  echo "✅"
  ((PASSED++))
else
  echo "❌"
  ((FAILED++))
fi

# 5. HAProxy
echo -n "[5/7] HAProxy 路由... "
if grep -q "host_${CLUSTER_NAME}" compose/infrastructure/haproxy.cfg; then
  echo "✅"
  ((PASSED++))
else
  echo "❌"
  ((FAILED++))
fi

# 6. CSV
echo -n "[6/7] CSV 配置... "
if grep -q "^${CLUSTER_NAME}," config/environments.csv; then
  echo "✅"
  ((PASSED++))
else
  echo "❌"
  ((FAILED++))
fi

# 7. whoami HTTP
echo -n "[7/7] whoami HTTP... "
HTTP_CODE=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://whoami.${CLUSTER_NAME}.${BASE_DOMAIN}" 2>/dev/null || echo "timeout")
if [ "$HTTP_CODE" = "200" ]; then
  echo "✅"
  ((PASSED++))
elif [ "$HTTP_CODE" = "404" ]; then
  echo "⚠️ (404 可接受)"
  ((PASSED++))
else
  echo "❌ ($HTTP_CODE)"
  ((FAILED++))
fi

echo ""
echo "结果: $PASSED/7 通过, $FAILED/7 失败"

if [ $FAILED -eq 0 ]; then
  echo "✅ 验收通过"
  exit 0
else
  echo "❌ 验收失败"
  exit 1
fi
```

**使用方法**：
```bash
chmod +x scripts/validate_cluster.sh
scripts/validate_cluster.sh test-123456
```

---

**完成时间**: 预计整个流程需要 5-10 分钟  
**报告生成**: 2025-10-20 14:50 CST

