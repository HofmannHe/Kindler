# GitOps 架构文档

## 概述

本项目实现了基于 ArgoCD 的 GitOps 架构，实现应用和基础设施的声明式管理。

### 仓库区分（重要）

- Kindler 仓库（本仓库）：脚本与基础设施代码，不适用“生效/归档分支”约定。
- GitOps 仓库（应用仓库）：ArgoCD 同步的目标仓库，必须执行“生效/归档分支”策略。

生效/归档分支策略（针对 GitOps 仓库）：
- 生效分支（Active）= SQLite `clusters` 表中的业务集群集合（排除 `devops`），分支名与环境名一致。
- 归档分支（Archive）= 不在数据库集合中的历史分支，迁移至 `archive/<env>-<YYYYMMDD-HHMMSS>` 并删除原活跃分支。
- 受保护分支：`main master develop release devops`（可通过 `GIT_RESERVED_BRANCHES` 配置）。
- 同步工具：`tools/git/sync_git_from_db.sh`（支持 DRY_RUN），`scripts/create_env.sh` 仅在分支创建成功后才进行 ApplicationSet 同步。

## 当前实施状态

### ✅ 已实施：方案 A - 应用层 GitOps

**状态**：生产就绪，所有环境正常运行

**架构**：
```
Git 仓库 (devops)
  ├── 分支: dev, uat, prod, dev-k3d, uat-k3d, prod-k3d, rttr-dev, rttr-uat 等
  ├── deploy/ (whoami Helm Chart)
  └── manifests/argocd/whoami-applicationset.yaml (List Generator)
       ↓
  ArgoCD ApplicationSet
       ↓
  生成 8 个 whoami Applications
       ↓
  部署到对应集群
```

**核心组件**：
- **ApplicationSet**: `manifests/argocd/whoami-applicationset.yaml`
- **Generator 类型**: List Generator
- **管理应用**: whoami（示例应用）
- **部署目标**: 8个集群（3 kind + 5 k3d）

**验证结果**：
```bash
# 测试命令
for env in dev uat prod dev-k3d uat-k3d prod-k3d rttr-dev rttr-uat; do
  provider=$(grep "^${env}," config/environments.csv | cut -d',' -f2 | tr -d ' ')
  curl -s "http://whoami.${provider}.${env}.192.168.51.30.sslip.io"
done

# 成功率: 8/8 (100%)
```

### 🔄 计划中：方案 B - 完整 GitOps 架构（可选增强）

**目标**：基础设施也通过 GitOps 管理

**架构设计**：
```
Git 仓库 (devops) - master 分支
  ├── infrastructure/ (Helm Charts)
  │   ├── charts/edge-agent/
  │   ├── charts/traefik/
  │   └── Chart.yaml (父 Chart)
  └── argocd/applicationsets/infrastructure-base.yaml (Cluster Generator)
       ↓
  ArgoCD ApplicationSet (自动发现集群)
       ↓
  为每个集群生成 infrastructure Application
       ↓
  自动部署 Edge Agent + Traefik
```

**优势**：
- ✅ 新集群注册后自动部署基础设施（无需手动操作）
- ✅ 基础设施配置统一管理，版本控制
- ✅ 集群删除后自动清理相关资源
- ✅ 支持基础设施的滚动更新

**风险**：
- ⚠️ 复杂度增加（ApplicationSet 模板渲染）
- ⚠️ 调试难度上升（需要理解 Generator 逻辑）
- ⚠️ 迁移期间可能影响服务稳定性

**实施状态**：已创建 Helm Charts 和 ApplicationSet，但未启用

## 集群注册与标签策略

### 集群注册时添加的元数据

**Labels**（用于 ApplicationSet Selector）：
```yaml
env: <环境名>              # dev, uat, prod, dev-k3d 等
provider: <k3d|kind>       # 集群类型
type: <business|management> # 业务集群或管理集群
```

**Annotations**（用于传递动态值）：
```yaml
portainer-edge-id: <EDGE_ID>      # Portainer Edge Agent ID
portainer-edge-key: <EDGE_KEY>    # Portainer Edge Agent Key
```

### 注册脚本

**文件**: `scripts/argocd_register_kubectl.sh`

**核心逻辑**：
```bash
# 1. 从 Portainer 获取 Edge 凭证
get_portainer_credentials() {
  # 查询 Kubernetes Secret (portainer-edge-creds)
  # 返回: edge-id|edge-key
}

# 2. 创建 ArgoCD Cluster Secret
kubectl create secret generic cluster-$name \
  --from-literal=name=$name \
  --from-literal=server=$server \
  --from-literal=config="..." \
  --dry-run=client -o yaml | \
kubectl label --local -f - \
  env=$env \
  provider=$provider \
  type=business --overwrite -o yaml | \
kubectl annotate --local -f - \
  portainer-edge-id=$edge_id \
  portainer-edge-key=$edge_key \
  --overwrite -o yaml | \
kubectl apply -n argocd -f -
```

## ApplicationSet 配置详解

### whoami ApplicationSet (当前使用)

**文件**: `manifests/argocd/whoami-applicationset.yaml`

**Generator 类型**: List Generator

**配置示例**：
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: whoami
  namespace: argocd
spec:
  goTemplate: true
  generators:
  - list:
      elements:
      - env: dev
        hostEnv: kind.dev
        branch: dev
        clusterName: dev
      - env: dev-k3d
        hostEnv: k3d.dev-k3d
        branch: dev-k3d
        clusterName: dev-k3d
      # ... 其他环境
  template:
    metadata:
      name: 'whoami-{{.env}}'
    spec:
      source:
        repoURL: 'http://git.devops.192.168.51.30.sslip.io/fc005/devops.git'
        path: deploy
        targetRevision: '{{.branch}}'
        helm:
          parameters:
          - name: ingress.host
            value: 'whoami.{{.hostEnv}}.192.168.51.30.sslip.io'
```

**优点**：
- ✅ 简单直观，易于理解和维护
- ✅ 显式配置，所有环境一目了然
- ✅ 稳定可靠，成功率 100%

**缺点**：
- ❌ 新环境需手动添加到列表
- ❌ 环境较多时配置冗长

### infrastructure ApplicationSet (已创建但未启用)

**文件**: `argocd/applicationsets/infrastructure-base.yaml`

**Generator 类型**: Cluster Generator

**配置示例**：
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: infrastructure-base
  namespace: argocd
spec:
  goTemplate: true
  generators:
  - clusters:
      selector:
        matchExpressions:
        - key: argocd.argoproj.io/secret-type
          operator: In
          values: [cluster]
        - key: type
          operator: NotIn
          values: [management]  # 排除 devops 集群
  template:
    metadata:
      name: 'infrastructure-{{.name}}'
    spec:
      source:
        repoURL: 'http://git.devops.192.168.51.30.sslip.io/fc005/devops.git'
        path: infrastructure
        targetRevision: master
        helm:
          parameters:
          - name: edgeAgent.edgeId
            value: '{{.metadata.annotations.portainer-edge-id}}'
          - name: edgeAgent.edgeKey
            value: '{{.metadata.annotations.portainer-edge-key}}'
```

**优点**：
- ✅ 自动发现集群，无需手动配置
- ✅ 新集群注册后自动部署基础设施
- ✅ 集群删除后自动清理

**挑战**：
- ⚠️ 模板渲染复杂（annotations 为空导致失败）
- ⚠️ 调试困难（需查看 ApplicationSet Controller 日志）

## Git 分支策略

### 当前分支列表

```bash
$ git ls-remote http://git.devops.192.168.51.30.sslip.io/fc005/devops.git

master            # 主分支，基础设施配置
dev               # kind-dev 环境
uat               # kind-uat 环境
prod              # kind-prod 环境
dev-k3d           # k3d-dev-k3d 环境
uat-k3d           # k3d-uat-k3d 环境
prod-k3d          # k3d-prod-k3d 环境
debug-k3d         # k3d-debug-k3d 环境
rttr-dev          # k3d-rttr-dev 环境
rttr-uat          # k3d-rttr-uat 环境
test-final        # k3d-test-final 环境
test-k3d-fixed    # k3d-test-k3d-fixed 环境
```

### 分支用途

- **master**: 基础设施配置、ApplicationSet 定义、脚本
- **环境分支**: 应用配置，分支名 = 环境名

### 分支创建

```bash
# 为新环境创建分支
git checkout -b <env-name> master
git push devops <env-name>
```

## 部署流程

### 应用部署流程（当前）

```
1. 开发者提交代码到 Git 分支
   ↓
2. ArgoCD 检测到 Git 变化（每3分钟轮询）
   ↓
3. ArgoCD 同步 Application
   ↓
4. Helm 渲染模板
   ↓
5. kubectl apply 到目标集群
   ↓
6. Traefik 配置 Ingress 路由
   ↓
7. 服务可通过域名访问
```

### 基础设施部署流程（脚本方式，当前使用）

```
1. 运行 scripts/create_env.sh
   ↓
2. 创建 k3d/kind 集群
   ↓
3. 部署 Traefik (kubectl apply)
   ↓
4. 注册到 Portainer，获取 Edge 凭证
   ↓
5. 部署 Edge Agent (kubectl apply)
   ↓
6. 注册到 ArgoCD（添加 labels/annotations）
   ↓
7. 配置 HAProxy 路由
```

### 基础设施部署流程（GitOps 方式，计划中）

```
1. 运行 scripts/create_env.sh
   ↓
2. 创建 k3d/kind 集群
   ↓
3. 注册到 Portainer，获取 Edge 凭证
   ↓
4. 注册到 ArgoCD（添加 labels/annotations，包含 edge-id）
   ↓
5. ApplicationSet 自动检测到新集群
   ↓
6. 生成 infrastructure Application
   ↓
7. ArgoCD 自动部署 Edge Agent + Traefik
   ↓
8. 配置 HAProxy 路由
```

## 域名规范

### 域名格式

```
<service>.<provider>.<env>.<base-domain>

示例：
- whoami.kind.dev.192.168.51.30.sslip.io
- whoami.k3d.dev-k3d.192.168.51.30.sslip.io
- whoami.k3d.rttr-uat.192.168.51.30.sslip.io
```

### 路由配置

**HAProxy**：
- 基于域名的路由规则
- 自动匹配 `<service>.<provider>.<env>.` 模式
- 转发到集群 NodePort (30080)

**Traefik**：
- IngressClass: `traefik`
- 监听 NodePort 30080
- 根据 Ingress host 规则路由到 Service

## 监控与验证

### 验证 ArgoCD Applications

```bash
# 查看所有 Applications
kubectl --context k3d-devops get applications -n argocd

# 查看 whoami Applications
kubectl --context k3d-devops get applications -n argocd -l app=whoami

# 查看 Application 详细状态
kubectl --context k3d-devops describe application whoami-dev -n argocd
```

### 验证服务访问

```bash
# 测试所有 whoami 服务
for env in dev uat prod dev-k3d uat-k3d prod-k3d rttr-dev rttr-uat; do
  provider=$(grep "^${env}," config/environments.csv | cut -d',' -f2 | tr -d ' ')
  echo -n "$env: "
  curl -s "http://whoami.${provider}.${env}.192.168.51.30.sslip.io" | head -1
done
```

### 验证集群注册

```bash
# 查看已注册集群
kubectl --context k3d-devops get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster

# 查看集群标签
kubectl --context k3d-devops get secret cluster-dev -n argocd -o jsonpath='{.metadata.labels}' | jq '.'
```

## 故障排查

### Application 状态异常

```bash
# 查看 Application 详细状态
kubectl --context k3d-devops describe application <app-name> -n argocd

# 查看 ApplicationSet 状态
kubectl --context k3d-devops get applicationset <name> -n argocd -o yaml

# 查看 ArgoCD 日志
kubectl --context k3d-devops logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

### 服务无法访问

1. **检查 Pod 状态**：
   ```bash
   kubectl --context k3d-<env> get pods -n default
   ```

2. **检查 Ingress**：
   ```bash
   kubectl --context k3d-<env> get ingress -n default
   ```

3. **检查 Traefik**：
   ```bash
   kubectl --context k3d-<env> get pods -n kube-system -l app=traefik
   kubectl --context k3d-<env> logs -n kube-system -l app=traefik
   ```

4. **检查 HAProxy 路由**：
   ```bash
   docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep <env>
   ```

## 最佳实践

### 1. 环境隔离

- ✅ 每个环境使用独立的 Kubernetes 集群
- ✅ 通过 Git 分支隔离配置
- ✅ 通过 namespace 隔离应用（可选）

### 2. 配置管理

- ✅ 所有配置存储在 Git
- ✅ 使用 Helm values 参数化配置
- ✅ 敏感信息通过 Secret 管理（如 Edge Agent 凭证）

### 3. 部署策略

- ✅ 使用 ArgoCD 自动同步（automated sync）
- ✅ 启用 prune（删除集群中多余的资源）
- ✅ 启用 selfHeal（自动修复配置漂移）

### 4. 监控与告警

- ⏳ 集成 ArgoCD Notifications（待实施）
- ⏳ 监控 Application 健康状态（待实施）
- ⏳ 监控同步失败告警（待实施）

## 迁移指南

### 从脚本部署迁移到 GitOps

**当前状态**：应用层已 GitOps 化，基础设施仍使用脚本

**如需完全 GitOps 化**：

1. **准备阶段**：
   ```bash
   # 确保所有集群已添加正确的 labels 和 annotations
   ./scripts/argocd_register_kubectl.sh register <env> <provider>
   ```

2. **部署基础设施 ApplicationSet**：
   ```bash
   kubectl --context k3d-devops apply -f argocd/applicationsets/infrastructure-base.yaml
   ```

3. **验证自动部署**：
   ```bash
   # 等待 ApplicationSet 生成 Applications
   kubectl --context k3d-devops get applications -n argocd -l app.kubernetes.io/part-of=infrastructure
   ```

4. **测试新集群自动部署**：
   ```bash
   # 创建测试集群（不手动部署基础设施）
   ./scripts/create_env.sh -n test-gitops --no-traefik --no-edge-agent
   
   # 验证 ApplicationSet 自动部署
   sleep 60
   kubectl --context k3d-test-gitops get pods -A
   ```

5. **清理旧资源**（可选）：
   ```bash
   # 移除脚本部署的基础设施
   kubectl --context k3d-<env> delete -f manifests/...
   ```

## 总结

### 当前架构优势

✅ **应用层 GitOps**：成熟稳定，100% 成功率
✅ **基础设施脚本**：快速可靠，易于调试
✅ **混合模式**：兼顾灵活性和稳定性

### 后续演进路径

**路径 1：保持现状**（推荐）
- 应用继续使用 GitOps
- 基础设施保持脚本部署
- 稳定可靠，维护成本低

**路径 2：完全 GitOps**（可选）
- 基础设施也迁移到 GitOps
- 实现完全自动化
- 需要更多测试和验证

**路径 3：多仓库支持**（长期）
- 支持多个应用仓库
- 实现应用注册表机制
- 动态发现和部署应用

---

**文档版本**: 1.0
**最后更新**: 2025-10-15
**作者**: Kindler GitOps Team
