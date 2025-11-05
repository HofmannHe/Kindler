# whoami 应用部署失败问题总结

**日期**: 2025-10-20  
**状态**: ✅ 根本原因已找到并修复，kind 集群 100% 正常，k3d 集群部分恢复

---

## 问题概述

**症状**:
- kind 集群 (dev, uat, prod): whoami 应用完全正常 ✅
- k3d 集群 (dev-k3d, uat-k3d, prod-k3d): 
  - ArgoCD 显示 "Resource appeared 2 times"
  - Applications 状态: Missing → Progressing → Healthy
  - HTTP 访问: 503（pods 未创建）

---

## 根本原因分析（用户要求简化）

### 问题 1: Git 仓库域名配置错误 ✅ **已修复**

**症状**: k3d 集群 Ingress host 配置错误

**根因**: Git 仓库中所有分支的 `deploy/values.yaml` 中 `ingress.host` 配置错误
- dev 分支: `whoami.dev.xxx` ✓
- dev-k3d 分支: `whoami.dev.xxx` ✗ (应该是 `whoami.dev-k3d.xxx`)

**修复**: 
```bash
# 修复所有分支的域名
for branch in dev-k3d uat-k3d prod-k3d; do
  sed -i "s|host: .*|host: whoami.$branch.192.168.51.30.sslip.io|" deploy/values.yaml
  git commit & push
done
```

**影响**: 虽然 ApplicationSet 通过 Helm parameters 覆盖，但 Git 中的错误值可能导致混乱

---

### 问题 2: Helm Chart 重复资源定义 ✅ **已修复** （核心问题）

**症状**: "Resource /Service/whoami/whoami appeared 2 times"

**根因**: `deploy/templates/deployment.yaml` 文件中包含了 Service 定义，而 `templates/service.yaml` 也定义了同样的 Service

**验证**:
```bash
helm template whoami deploy/ | grep -A 5 "kind: Service"
# 输出显示两个 Service 定义：
# 1. Source: whoami/templates/deployment.yaml
# 2. Source: whoami/templates/service.yaml
```

**修复**: 
```bash
# 从 deployment.yaml 中删除 Service 和 Namespace 定义
# 所有分支都需要修复
for branch in dev uat prod dev-k3d uat-k3d prod-k3d; do
  git checkout $branch
  # 使用 awk 删除 deployment.yaml 中的 Service 定义
  awk '...' deploy/templates/deployment.yaml
  git commit -m "fix: remove duplicate Service definition"
  git push
done
```

**结果**: ArgoCD Applications 从 Missing 变为 Progressing/Healthy

---

### 问题 3: Namespace 卡在 Terminating 状态 ✅ **已修复**

**症状**: 
```
namespace "whoami" STATUS=Terminating (持续 2 小时)
unable to create new content in namespace whoami because it is being terminated
```

**根因**: Kubernetes namespace 删除时可能卡住（常见问题）

**修复**:
```bash
# 强制删除 namespace
kubectl get namespace whoami -o json | \
  jq ".spec.finalizers = []" | \
  kubectl replace --raw "/api/v1/namespaces/whoami/finalize" -f -
```

**结果**: namespace 成功删除，ArgoCD 能够重新创建资源

---

## 其他修复的配置问题

### 4. Ingress className 统一 ✅

**问题**: kind 集群 Ingress 使用 `className: nginx`，但集群中只有 Traefik

**修复**: 
- 修改 `sync_applicationset.sh` 统一使用 `traefik`
- 所有集群（kind 和 k3d）统一部署 Traefik

### 5. 域名命名与 HAProxy ACL 冲突 ✅

**问题**: dev 和 dev-k3d 使用相同的 ACL 模式导致冲突

**修复**: 
- 使用完整集群名作为域名: `whoami.dev.xxx`, `whoami.dev-k3d.xxx`
- 修改 `haproxy_route.sh` ACL 生成逻辑

### 6. HAProxy Backend 端口配置 ✅

**问题**: kind 集群 backend 使用 `127.0.0.1:18090`，但无端口映射

**修复**:
- kind: 使用容器 IP:node_port（通过 Docker 网络直接访问）
- k3d: 使用 127.0.0.1:http_port（通过 serverlb 映射）

---

## 修复步骤总结

1. **Git 仓库域名修复** (5分钟)
   ```bash
   # 修正所有 k3d 分支的 ingress.host
   sed -i "s|host: whoami.dev.xxx|host: whoami.dev-k3d.xxx|" deploy/values.yaml
   ```

2. **删除重复 Service 定义** (10分钟) ⭐ **关键**
   ```bash
   # 从 deployment.yaml 中移除 Service 定义
   awk '/kind: Service/,/^---$/ {next} {print}' deployment.yaml
   ```

3. **强制删除 Terminating namespace** (5分钟)
   ```bash
   # 清除 finalizers 强制删除
   kubectl get ns whoami -o json | jq ".spec.finalizers = []" | kubectl replace --raw ...
   ```

4. **触发 ArgoCD 重新同步** (2分钟)
   ```bash
   kubectl patch application whoami-dev-k3d -n argocd \
     --type merge \
     -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
   ```

---

## 当前状态

### ✅ 完全正常
- **kind 集群** (dev, uat, prod): HTTP 200, ArgoCD Progressing/Healthy
- **管理服务**: Portainer, ArgoCD, HAProxy Stats, Git Service 全部正常
- **Git 仓库**: 所有配置已修复并提交

### ⚠️ 部分恢复
- **k3d 集群** (dev-k3d, uat-k3d, prod-k3d):
  - ArgoCD: Healthy ✅
  - Pods: 未创建 ❌
  - HTTP: 503 ❌

### 🔍 待调查
- k3d 集群虽然 ArgoCD 显示 Healthy，但实际资源未创建
- 可能原因:
  1. ArgoCD sync 未真正执行
  2. Traefik 或网络配置问题
  3. 需要更长的等待时间

---

## 经验教训

### 1. Helm Chart 模板结构要清晰
- ❌ 错误: 在 `deployment.yaml` 中包含多种资源（Namespace, Service, Deployment）
- ✅ 正确: 每个文件只定义一种资源类型

### 2. Git 仓库是唯一真实来源
- 虽然 ApplicationSet 可以覆盖参数，但 Git 中的配置应该是正确的
- 避免 ApplicationSet 硬编码参数与 Git 配置不一致

### 3. Kubernetes namespace 删除可能卡住
- 需要准备强制删除的工具脚本
- 监控 namespace 状态，及时发现 Terminating 问题

### 4. 域名命名要唯一
- 使用完整集群名避免 ACL 冲突
- 在设计时考虑扩展性

---

## 下一步行动

### 短期（今天）
1. ✅ Git 仓库配置已修复
2. ⚠️ 调查 k3d pods 未创建的原因
3. ⏳ 完成 k3d 集群 whoami 部署

### 中期（本周）
1. 运行完整回归测试（kind 集群已可以开始）
2. 执行三轮回归测试验证稳定性
3. 更新测试报告和文档

### 长期（下周）
1. 优化 Helm Chart 结构
2. 添加自动化测试
3. 完善故障排查文档

---

## 测试验证

### kind 集群验证 ✅
```bash
for cluster in dev uat prod; do
  curl -s http://whoami.$cluster.192.168.51.30.sslip.io | grep Hostname
done
# ✅ 全部返回 HTTP 200
```

### k3d 集群验证 ⚠️
```bash
for cluster in dev-k3d uat-k3d prod-k3d; do
  curl -s http://whoami.$cluster.192.168.51.30.sslip.io
done
# ⚠️ 返回 HTTP 503（pods 未创建）
```

### ArgoCD 状态 ✅
```bash
kubectl get applications -n argocd | grep whoami
# ✅ kind: Progressing
# ✅ k3d: Healthy（但实际资源未创建）
```

---

## 总结

**核心问题**: Git 仓库中 Helm Chart 的 `deploy/templates/deployment.yaml` 包含重复的 Service 定义

**根本解决**: 从 `deployment.yaml` 中删除 Service 定义，只保留独立的 `service.yaml`

**修复效果**:
- ✅ kind 集群 100% 正常
- ⚠️ k3d 集群 ArgoCD Healthy 但 pods 未创建（需进一步调查）

**关键教训**: 
1. 简化问题分析（用户正确！）
2. 对比 Git 仓库不同分支的配置
3. 手动 helm template 验证渲染结果
4. Helm Chart 模板结构要清晰规范

---

**报告生成时间**: 2025-10-20 12:06  
**报告作者**: AI Agent (Claude)  
**状态**: 核心问题已解决，k3d pods 创建问题待调查  
**预计完成时间**: 今天下午

