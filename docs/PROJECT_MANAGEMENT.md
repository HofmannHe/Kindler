# Kindler 多项目管理指南

## 概述

Kindler 支持多项目管理功能，允许在同一个基础设施上运行多个独立的项目，每个项目都有独立的命名空间、资源配额和网络策略。

## 核心概念

### 项目隔离
- **命名空间隔离**：每个项目运行在独立的 Kubernetes 命名空间中
- **资源配额**：通过 ResourceQuota 限制每个项目的资源使用
- **网络策略**：通过 NetworkPolicy 控制项目间的网络访问
- **域名路由**：支持项目级域名模式 `<service>.<project>.<env>.<BASE_DOMAIN>`

### 项目配置
项目配置存储在 `config/projects.csv` 文件中，格式如下：
```csv
# project,env,namespace,team,cpu_limit,memory_limit,ingress_domain,created_at,description
demo-app,dev-k3d,project-demo-app,backend,2,4Gi,demo-app.dev-k3d.192.168.51.35.sslip.io,2025-10-13,Demo application
```

## 项目管理命令

### 创建项目
```bash
./scripts/project_manage.sh create \
  --project <project-name> \
  --env <environment> \
  --team <team-name> \
  --cpu-limit <cpu-limit> \
  --memory-limit <memory-limit> \
  --description "<description>"
```

**示例**：
```bash
./scripts/project_manage.sh create \
  --project demo-app \
  --env dev-k3d \
  --team backend \
  --cpu-limit 2 \
  --memory-limit 4Gi \
  --description "Demo application for testing"
```

### 查看项目
```bash
./scripts/project_manage.sh show --project <project-name> --env <environment>
```

### 列出项目
```bash
# 列出所有项目
./scripts/project_manage.sh list

# 列出指定环境的项目
./scripts/project_manage.sh list --env dev-k3d
```

### 更新项目
```bash
./scripts/project_manage.sh update \
  --project <project-name> \
  --cpu-limit <new-cpu-limit> \
  --memory-limit <new-memory-limit> \
  --description "<new-description>"
```

### 删除项目
```bash
./scripts/project_manage.sh delete --project <project-name> --env <environment>
```

### 生成项目 kubeconfig
```bash
./scripts/project_manage.sh kubeconfig \
  --project <project-name> \
  --env <environment> \
  --output <output-file>
```

## HAProxy 项目级路由

### 添加项目路由
```bash
./scripts/haproxy_project_route.sh add <project-name> --env <environment> [--node-port <port>]
```

**示例**：
```bash
./scripts/haproxy_project_route.sh add demo-app --env dev-k3d --node-port 30080
```

### 移除项目路由
```bash
./scripts/haproxy_project_route.sh remove <project-name> --env <environment>
```

### 域名模式
项目级路由支持以下域名模式：
- `<service>.<project>.<env>.<BASE_DOMAIN>`
- 例如：`whoami.demo-app.dev-k3d.192.168.51.35.sslip.io`

## ArgoCD 项目管理

### 创建 AppProject
```bash
./scripts/argocd_project.sh create \
  --project <project-name> \
  --repo <git-repo-url> \
  --namespace <project-namespace>
```

### 添加应用
```bash
./scripts/argocd_project.sh add-app \
  --project <project-name> \
  --app <app-name> \
  --path <path-in-repo> \
  --env <environment>
```

### 删除 AppProject
```bash
./scripts/argocd_project.sh delete --project <project-name>
```

## 项目模板

### 命名空间模板
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: PROJECT_NAMESPACE_PLACEHOLDER
  labels:
    project: PROJECT_NAME_PLACEHOLDER
    team: PROJECT_TEAM_PLACEHOLDER
    environment: PROJECT_ENV_PLACEHOLDER
    managed-by: kindler
    created-at: PROJECT_CREATED_AT_PLACEHOLDER
  annotations:
    kindler.io/project-description: "PROJECT_DESCRIPTION_PLACEHOLDER"
    kindler.io/cpu-limit: "PROJECT_CPU_LIMIT_PLACEHOLDER"
    kindler.io/memory-limit: "PROJECT_MEMORY_LIMIT_PLACEHOLDER"
```

### 资源配额模板
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: project-quota
  namespace: PROJECT_NAMESPACE_PLACEHOLDER
spec:
  hard:
    requests.cpu: "PROJECT_CPU_LIMIT_PLACEHOLDER"
    requests.memory: "PROJECT_MEMORY_LIMIT_PLACEHOLDER"
    limits.cpu: "PROJECT_CPU_LIMIT_PLACEHOLDER"
    limits.memory: "PROJECT_MEMORY_LIMIT_PLACEHOLDER"
    pods: "10"
    services: "5"
    configmaps: "10"
    secrets: "10"
    persistentvolumeclaims: "2"
```

### 限制范围模板
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: project-limits
  namespace: PROJECT_NAMESPACE_PLACEHOLDER
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    max:
      cpu: "2"
      memory: "2Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    type: Container
```

### 网络策略模板
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: project-network-policy
  namespace: PROJECT_NAMESPACE_PLACEHOLDER
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
```

## 完整示例

### 1. 创建项目
```bash
./scripts/project_manage.sh create \
  --project demo-app \
  --env dev-k3d \
  --team backend \
  --cpu-limit 2 \
  --memory-limit 4Gi \
  --description "Demo application for testing"
```

### 2. 查看项目
```bash
./scripts/project_manage.sh show --project demo-app --env dev-k3d
```

### 3. 添加 HAProxy 路由
```bash
./scripts/haproxy_project_route.sh add demo-app --env dev-k3d --node-port 30080
```

### 4. 创建 ArgoCD AppProject
```bash
./scripts/argocd_project.sh create \
  --project demo-app \
  --repo https://github.com/example/demo-app.git \
  --namespace project-demo-app
```

### 5. 部署应用
```bash
./scripts/argocd_project.sh add-app \
  --project demo-app \
  --app whoami \
  --path deploy/ \
  --env dev-k3d
```

### 6. 测试访问
```bash
curl -H 'Host: whoami.demo-app.dev-k3d.192.168.51.35.sslip.io' http://192.168.51.30
```

### 7. 生成项目 kubeconfig
```bash
./scripts/project_manage.sh kubeconfig \
  --project demo-app \
  --env dev-k3d \
  --output ~/.kube/demo-app-dev-k3d.yaml
```

### 8. 清理项目
```bash
./scripts/project_manage.sh delete --project demo-app --env dev-k3d
```

## 故障排除

### 常见问题

1. **项目创建失败**
   - 检查环境是否存在：`kubectl config get-contexts`
   - 检查集群是否运行：`kubectl get nodes --context <context>`

2. **HAProxy 路由不工作**
   - 检查 HAProxy 配置：`docker logs haproxy-gw`
   - 检查域名解析：`curl -H 'Host: <domain>' http://192.168.51.30`

3. **ArgoCD 连接失败**
   - 检查 ArgoCD 服务状态：`kubectl get pods -n argocd --context k3d-devops`
   - 检查 ArgoCD 访问地址：`curl -I http://192.168.51.30:23081`

4. **命名空间删除卡住**
   - 强制删除：`kubectl delete namespace <namespace> --force --grace-period=0`
   - 检查 finalizers：`kubectl get namespace <namespace> -o yaml`

### 调试命令

```bash
# 检查项目配置
cat config/projects.csv

# 检查 HAProxy 配置
docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg

# 检查 ArgoCD 状态
kubectl --context k3d-devops get pods -n argocd

# 检查项目资源
kubectl --context <context> get all -n <project-namespace>
```

## 最佳实践

1. **项目命名**：使用有意义的项目名称，避免特殊字符
2. **资源限制**：根据实际需求设置合理的 CPU 和内存限制
3. **环境隔离**：不同环境使用不同的项目配置
4. **定期清理**：定期清理不再使用的项目
5. **监控资源**：监控项目资源使用情况，及时调整配额

## 与 KINDLER_NS 的关系

- **KINDLER_NS**：用于开发环境隔离（临时性）
- **多项目管理**：用于生产环境的项目隔离（持久性）
- 两者可以共存，不冲突
- KINDLER_NS 主要用于开发分支隔离，多项目管理用于生产项目隔离