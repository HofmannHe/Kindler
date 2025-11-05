# 集群生命周期验收 - 快速开始

## 🎯 操作流程

### 1️⃣ 创建测试集群

```bash
# 生成唯一的集群名称
TEST_CLUSTER="test-$(date +%s)"
echo "测试集群: $TEST_CLUSTER"

# 创建 k3d 集群
scripts/create_env.sh -n $TEST_CLUSTER -p k3d

# 等待 60 秒让所有服务就绪
echo "等待服务就绪（60秒）..."
sleep 60
```

### 2️⃣ 验收集群状态

```bash
# 使用快速验收脚本
scripts/validate_cluster.sh $TEST_CLUSTER exist
```

**预期结果**：
```
=== 验收集群: test-1738158 (模式: exist) ===

📋 验收标准：所有检查项必须通过

[1/7] K8s 集群运行状态... ✅ Ready
[2/7] 数据库记录... ✅ 存在
[3/7] Git 分支... ✅ 存在
[4/7] ArgoCD Application... ✅ Synced / Healthy
[5/7] HAProxy 路由配置... ✅ 已配置
[6/7] CSV 配置... ✅ 存在
[7/7] whoami HTTP 访问... ✅ HTTP 200

========================================
验收结果: 7/7 通过, 0/7 失败
========================================
✅ 验收通过
```

### 3️⃣ 测试 whoami 服务

```bash
# 获取域名
source config/clusters.env
DOMAIN="whoami.${TEST_CLUSTER}.${BASE_DOMAIN}"
echo "访问地址: http://$DOMAIN"

# 测试访问
curl -s http://$DOMAIN | head -5
```

**预期输出**：
```
Hostname: whoami-694564c467-xxxxx
IP: 127.0.0.1
IP: ::1
RemoteAddr: 10.x.x.x:xxxxx
GET / HTTP/1.1
```

### 4️⃣ 删除测试集群

```bash
# 删除集群
scripts/delete_env.sh -n $TEST_CLUSTER

# 等待 30 秒让清理完成
echo "等待清理完成（30秒）..."
sleep 30
```

### 5️⃣ 验收清理状态

```bash
# 验收删除
scripts/validate_cluster.sh $TEST_CLUSTER deleted
```

**预期结果**：
```
=== 验收集群: test-1738158 (模式: deleted) ===

📋 验收标准：所有资源必须已清理

[1/7] K8s 集群已删除... ✅ 无法访问
[2/7] 数据库记录已删除... ✅ 已删除
[3/7] Git 分支已删除... ✅ 已删除
[4/7] ArgoCD Application 已删除... ✅ 已删除
[5/7] HAProxy 路由已删除... ✅ 已删除
[6/7] CSV 配置已删除... ✅ 已删除
[7/7] Portainer 环境（手动检查）... ⚠️ 需手动确认

========================================
验收结果: 7/7 通过, 0/7 失败
========================================
✅ 验收通过
```

---

## 📋 验收清单

### ✅ 创建后验收（7 项必须全通过）

- [ ] K8s 集群：节点 Ready
- [ ] 数据库：记录存在
- [ ] Git 分支：分支存在
- [ ] ArgoCD：Application Synced/Healthy
- [ ] HAProxy：路由已配置
- [ ] CSV：配置存在
- [ ] whoami：HTTP 200 正常访问

### ✅ 删除后验收（7 项必须全通过）

- [ ] K8s 集群：已删除
- [ ] 数据库：记录已删除
- [ ] Git 分支：分支已删除
- [ ] ArgoCD：Application 已删除
- [ ] HAProxy：路由已删除
- [ ] CSV：配置已删除
- [ ] Portainer：环境已删除（需手动确认）

---

## 🔍 手动验收（可选）

### 查看 Portainer

```bash
echo "Portainer: https://portainer.devops.192.168.51.30.sslip.io"
```

**检查点**：
1. 创建后：环境列表显示该集群，状态 online
2. 删除后：环境列表不显示该集群

### 查看 ArgoCD

```bash
echo "ArgoCD: http://argocd.devops.192.168.51.30.sslip.io"
# 账号: admin
# 密码: 见 config/secrets.env 中的 ARGOCD_ADMIN_PASSWORD
```

**检查点**：
1. 创建后：Applications 列表显示 `whoami-<cluster>`, 状态 Synced + Healthy
2. 删除后：Applications 列表不显示该 Application

### 查看 HAProxy Stats

```bash
echo "HAProxy: http://haproxy.devops.192.168.51.30.sslip.io/stat"
```

**检查点**：
1. 创建后：Backend 列表显示 `be_<cluster>`
2. 删除后：Backend 列表不显示该 Backend

---

## 🚨 常见问题

### whoami 返回 404

**原因**: Git 服务不可用或分支未同步  
**解决**: 这是可接受的状态（验收脚本会标记为 ⚠️）

**如果需要修复**：
```bash
# 检查 Git 服务
curl -I http://git.devops.192.168.51.30.sslip.io

# 手动触发 ArgoCD 同步
kubectl --context k3d-devops patch application whoami-$TEST_CLUSTER -n argocd \
  --type='json' -p='[{"op": "replace", "path": "/operation", "value": {"sync": {"revision": "HEAD"}}}]'

# 等待 30 秒后重新测试
sleep 30
curl http://whoami.$TEST_CLUSTER.192.168.51.30.sslip.io
```

### whoami 返回 503

**原因**: Ingress Controller 或应用未就绪  
**诊断**：
```bash
# 检查 Ingress Controller
kubectl --context k3d-$TEST_CLUSTER get pods -A | grep traefik

# 检查 whoami 应用
kubectl --context k3d-$TEST_CLUSTER get pods -n whoami

# 查看 Ingress 配置
kubectl --context k3d-$TEST_CLUSTER get ingress -n whoami whoami -o yaml
```

### Portainer 显示 offline

**原因**: Edge Agent 未运行或连接失败  
**诊断**：
```bash
# 检查 Edge Agent
kubectl --context k3d-$TEST_CLUSTER get pods -n portainer

# 查看日志
kubectl --context k3d-$TEST_CLUSTER logs -n portainer -l app=edge-agent
```

---

## 📚 详细文档

完整的验收步骤和故障排查，请参考：
- 📖 [集群生命周期验收指引](CLUSTER_LIFECYCLE_VALIDATION_GUIDE.md)

---

**总耗时**: 约 5-10 分钟  
**创建时间**: 2025-10-20 15:00 CST

