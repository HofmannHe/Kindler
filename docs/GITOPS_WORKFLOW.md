# GitOps 工作流

本文档说明 Kindler 中的 GitOps 工作流程，基于 Gitea + ArgoCD + ApplicationSet 实现自动化部署。

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│ GitOps 流程                                                 │
│                                                              │
│  开发者                                                      │
│    │                                                         │
│    ├─> 提交代码到 Git 分支                                  │
│    │    ├─> develop   → dev 环境                           │
│    │    ├─> release   → uat 环境                           │
│    │    └─> master    → prod 环境                          │
│    │                                                         │
│    ↓                                                         │
│  Gitea (Git 服务)                                           │
│    │                                                         │
│    ↓                                                         │
│  ArgoCD (同步引擎)                                          │
│    │                                                         │
│    ├─> ApplicationSet 生成 Applications                    │
│    │    └─> 根据 environments.csv 动态生成                 │
│    │                                                         │
│    ↓                                                         │
│  业务集群 (dev/uat/prod)                                   │
│    └─> whoami 应用部署                                     │
└─────────────────────────────────────────────────────────────┘
```

## 核心组件

### 1. Gitea
- **位置**: devops 集群
- **访问**: http://git.devops.192.168.51.30.sslip.io
- **用途**: 托管应用代码和配置
- **账户**: gitea / (secrets.env 中的密码)

### 2. ArgoCD
- **位置**: devops 集群
- **访问**: http://argocd.devops.192.168.51.30.sslip.io
- **用途**: 监听 Git 仓库变化，自动同步到集群
- **账户**: admin / (secrets.env 中的密码)

### 3. ApplicationSet
- **定义**: manifests/argocd/whoami-applicationset.yaml
- **生成脚本**: scripts/sync_applicationset.sh
- **驱动配置**: config/environments.csv
- **用途**: 为每个环境自动生成 ArgoCD Application

## 分支与环境映射

| Git 分支 | 目标环境 | 域名模式 | 说明 |
|----------|----------|----------|------|
| **develop** | dev, dev-k3d | whoami.dev.* | 开发环境 |
| **release** | uat, uat-k3d | whoami.uat.* | 预发布环境 |
| **master** | prod, prod-k3d | whoami.prod.* | 生产环境 |
| **main** | debug-k3d, test-* | whoami.*.* | 其他测试环境 |

> **映射规则**: 由 `sync_applicationset.sh` 中的 `get_branch_for_env()` 函数定义

## whoami 应用配置

### 仓库结构
```
whoami/
├── README.md
└── deploy/                # Helm Chart
    ├── Chart.yaml
    ├── values.yaml        # 默认配置
    └── templates/
        ├── deployment.yaml
        ├── service.yaml
        └── ingress.yaml
```

### 配置差异分析

#### Git 仓库中的配置（静态）
各分支的 `deploy/values.yaml` 唯一差异是 `ingress.host`：

| 分支 | ingress.host | 其他配置 |
|------|--------------|----------|
| develop | whoami.devops.* | 完全相同 |
| release | whoami.uat.* | 完全相同 |
| master | whoami.prod.* | 完全相同 |

**共同配置**：
```yaml
image:
  repository: traefik/whoami
  tag: latest
  pullPolicy: IfNotPresent

replicaCount: 1

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  className: traefik
  # host 是唯一差异
```

#### ApplicationSet 动态覆盖（运行时）
ApplicationSet 会在部署时覆盖 `ingress.host`：

```yaml
helm:
  parameters:
  - name: ingress.host
    value: 'whoami.{{.env}}.192.168.51.30.sslip.io'
```

**实际生效的域名**（按环境）：
- dev 环境: `whoami.dev.192.168.51.30.sslip.io`
- uat 环境: `whoami.uat.192.168.51.30.sslip.io`
- prod 环境: `whoami.prod.192.168.51.30.sslip.io`
- dev-k3d 环境: `whoami.dev-k3d.192.168.51.30.sslip.io`

### 最小化差异评估

✅ **已实现最小化差异**：
- 应用代码：所有环境使用相同镜像
- 资源配置：replicaCount、service 完全一致
- Ingress 配置：仅域名不同（必要差异）

⚠️ **优化空间**：
- Git 分支中的 `ingress.host` 硬编码会被 ApplicationSet 覆盖
- 建议统一为空值或占位符，由 ApplicationSet 完全控制

## 工作流程示例

### 场景1：开发新功能
```bash
# 1. 开发者在本地修改代码
cd /path/to/whoami
git checkout develop

# 2. 修改应用代码（假设修改 README.md）
echo "New feature" >> README.md

# 3. 提交并推送
git add .
git commit -m "feat: add new feature"
git push origin develop

# 4. ArgoCD 自动检测变化并同步
#    - 监听 develop 分支
#    - 部署到 dev 和 dev-k3d 集群
#    - 更新 whoami 应用

# 5. 验证部署
curl http://whoami.dev.192.168.51.30.sslip.io
curl http://whoami.dev-k3d.192.168.51.30.sslip.io
```

### 场景2：发布到 UAT
```bash
# 1. 从 develop 合并到 release
git checkout release
git merge develop
git push origin release

# 2. ArgoCD 自动同步到 uat/uat-k3d 集群

# 3. 验证
curl http://whoami.uat.192.168.51.30.sslip.io
curl http://whoami.uat-k3d.192.168.51.30.sslip.io
```

### 场景3：生产发布
```bash
# 1. 从 release 合并到 master
git checkout master
git merge release
git tag v1.0.0
git push origin master --tags

# 2. ArgoCD 自动同步到 prod/prod-k3d 集群

# 3. 验证
curl http://whoami.prod.192.168.51.30.sslip.io
curl http://whoami.prod-k3d.192.168.51.30.sslip.io
```

## 环境生命周期与 GitOps 集成

### 新增环境
```bash
# 1. 编辑 config/environments.csv，添加新环境
echo "staging,k3d,30080,19010,true,true,48100,48450" >> config/environments.csv

# 2. 创建集群（自动注册到 ArgoCD + 同步 ApplicationSet）
./scripts/create_env.sh -n staging

# 3. ApplicationSet 自动为 staging 创建 whoami Application
#    分支选择: staging -> main (根据 get_branch_for_env 规则)
#    域名: whoami.staging.192.168.51.30.sslip.io
```

### 删除环境
```bash
# 1. 删除集群（自动清理 CSV + 同步 ApplicationSet）
./scripts/delete_env.sh -n staging

# 2. ApplicationSet 自动移除 staging 相关 Application
```

## ApplicationSet 配置详解

### 生成规则
```yaml
generators:
- list:
    elements:
    # 由 sync_applicationset.sh 从 environments.csv 生成
    - env: dev
      branch: develop        # 映射规则：dev* -> develop
      clusterName: dev
    - env: uat
      branch: release        # 映射规则：uat* -> release
      clusterName: uat
    - env: prod
      branch: master         # 映射规则：prod* -> master
      clusterName: prod
```

### Application 模板
```yaml
template:
  metadata:
    name: 'whoami-{{.env}}'
  spec:
    source:
      repoURL: http://git.devops.192.168.51.30.sslip.io/gitea/whoami.git
      path: deploy
      targetRevision: '{{.branch}}'
      helm:
        parameters:
        - name: ingress.host
          value: 'whoami.{{.env}}.192.168.51.30.sslip.io'
    destination:
      name: '{{.clusterName}}'
      namespace: default
    syncPolicy:
      automated:
        prune: true      # 自动删除 Git 中不存在的资源
        selfHeal: true   # 自动修复集群中的配置漂移
```

## 监控与验证

### ArgoCD UI
访问 http://argocd.devops.192.168.51.30.sslip.io 查看：
- Applications 状态（Synced/OutOfSync）
- 同步历史和事件
- 资源健康状态

### 命令行验证
```bash
# 查看所有 Applications
kubectl --context k3d-devops get applications -n argocd

# 查看特定 Application 详情
kubectl --context k3d-devops get application whoami-dev -n argocd -o yaml

# 手动触发同步
kubectl --context k3d-devops patch application whoami-dev -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### 应用访问验证
```bash
# 验证所有环境的 whoami 应用
for env in dev uat prod dev-k3d uat-k3d prod-k3d; do
  echo "=== $env ==="
  curl -s http://whoami.$env.192.168.51.30.sslip.io | grep -E "Hostname|IP"
done
```

## 故障排除

### Application 一直处于 Unknown 状态
**原因**: ArgoCD 无法连接目标集群 API Server

**检查**:
```bash
# 查看 cluster secret
kubectl --context k3d-devops get secret -n argocd cluster-dev -o yaml

# 检查 server 地址是否可达
kubectl --context k3d-devops get secret -n argocd cluster-dev \
  -o jsonpath='{.data.server}' | base64 -d
```

**已知问题**: kind/k3d 集群的 API Server 地址为 `127.0.0.1:port`，从 devops 集群 Pod 内无法访问。

### Application OutOfSync
**原因1**: Git 仓库有新的 commit

**解决**: ArgoCD 会自动同步（如果配置了 `automated`）

**原因2**: 集群中的资源被手动修改

**解决**: ArgoCD selfHeal 会自动修复

### ApplicationSet 没有生成 Application
**检查**:
```bash
# 查看 ApplicationSet 状态
kubectl --context k3d-devops get applicationset -n argocd whoami -o yaml

# 检查是否有错误
kubectl --context k3d-devops describe applicationset -n argocd whoami
```

**常见原因**:
- `environments.csv` 格式错误
- `sync_applicationset.sh` 未执行
- cluster secret 不存在

## 最佳实践

### 1. 分支策略
- ✅ develop: 频繁集成，自动部署到 dev
- ✅ release: 稳定版本，部署到 uat 进行验证
- ✅ master: 生产就绪，仅部署到 prod
- ✅ 使用 tag 标记生产版本

### 2. 配置管理
- ✅ 环境差异仅限必要配置（域名、副本数）
- ✅ 敏感信息使用 Kubernetes Secret
- ✅ 使用 Helm parameters 覆盖而非多个 values 文件

### 3. 部署安全
- ✅ 使用 `syncPolicy.automated.prune` 自动清理
- ✅ 使用 `syncPolicy.automated.selfHeal` 防止配置漂移
- ⚠️ 生产环境可考虑禁用 `automated`，改为手动审批

### 4. 环境管理
- ✅ 所有环境配置在 `environments.csv` 中维护
- ✅ 使用 `create_env.sh` 自动注册到 ArgoCD
- ✅ 使用 `delete_env.sh` 自动清理 ApplicationSet

## 扩展阅读

- [ArgoCD ApplicationSet 官方文档](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [GitOps 最佳实践](https://www.weave.works/technologies/gitops/)
- [Helm Chart 开发指南](https://helm.sh/docs/chart_template_guide/)
