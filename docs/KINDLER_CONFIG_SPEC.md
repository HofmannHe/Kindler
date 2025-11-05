# Kindler 配置文件规范

版本: v1  
最后更新: 2025-10-17

## 概述

`.kindler.yaml` 是 Kindler 项目的环境配置文件，用于定义 Kubernetes 集群的创建参数、网络配置和第三方服务集成。该文件存储在外部 Git 仓库的各个环境分支（`env/*`）的根目录中。

## 文件位置

- **外部 Git 仓库**: 每个 `env/*` 分支的根目录
- **示例**: `env/dev/.kindler.yaml`, `env/uat/.kindler.yaml`, `env/prod/.kindler.yaml`

## 完整配置示例

```yaml
version: v1

cluster:
  name: dev              # 环境名称（通常从分支名自动提取）
  provider: k3d          # 集群提供商: k3d 或 kind

network:
  http_port: 18090       # HAProxy HTTP 端口（宿主机）
  https_port: 18443      # HAProxy HTTPS 端口（宿主机）
  node_port: 30080       # Kubernetes NodePort（集群内部）
  pf_port: 19001         # Port-forward 端口（调试用）
  subnet: ""             # k3d 独立子网（可选，留空使用共享网络）

integrations:
  portainer:
    enabled: true                    # 是否注册到 Portainer
    tags: ["dev", "k3d", "business"] # Portainer 环境标签
  
  haproxy:
    enabled: true                    # 是否添加 HAProxy 路由
  
  argocd:
    enabled: true                    # 是否注册到 ArgoCD
    labels:                          # ArgoCD cluster secret 标签
      env: dev
      provider: k3d
      type: business
```

## 字段说明

### `version` (必需)

- **类型**: 字符串
- **值**: `v1`
- **说明**: 配置文件格式版本

### `cluster` (必需)

集群基本信息。

#### `cluster.name` (可选)

- **类型**: 字符串
- **默认值**: 从分支名自动提取（`env/dev` → `dev`）
- **说明**: 环境名称，通常不需要手动指定

#### `cluster.provider` (必需)

- **类型**: 字符串
- **可选值**: `k3d`, `kind`
- **说明**: Kubernetes 集群提供商
- **选择建议**:
  - `k3d`: 支持独立子网，更接近生产环境
  - `kind`: 共享网络，适合快速测试

### `network` (必需)

网络配置。

#### `network.http_port` (必需)

- **类型**: 整数
- **范围**: 1024-65535
- **说明**: HAProxy HTTP 端口映射到宿主机的端口
- **示例**: `18090`

#### `network.https_port` (必需)

- **类型**: 整数
- **范围**: 1024-65535
- **说明**: HAProxy HTTPS 端口映射到宿主机的端口
- **示例**: `18443`

#### `network.node_port` (必需)

- **类型**: 整数
- **范围**: 30000-32767
- **默认值**: `30080`
- **说明**: Kubernetes NodePort，用于内部服务暴露

#### `network.pf_port` (可选)

- **类型**: 整数
- **范围**: 1024-65535
- **说明**: Port-forward 端口，用于调试
- **示例**: `19001`

#### `network.subnet` (可选)

- **类型**: 字符串（CIDR 格式）
- **默认值**: `""`（空字符串，使用共享网络）
- **说明**: k3d 集群的独立子网
- **适用于**: 仅 k3d 集群
- **示例**: `"10.101.0.0/16"`, `"10.102.0.0/16"`
- **推荐分配**:
  - 共享网络（devops）: `172.18.0.0/16`（k3d-shared）
  - 业务集群: `10.101.0.0/16`, `10.102.0.0/16`, ...

### `integrations` (必需)

第三方服务集成配置。

#### `integrations.portainer` (必需)

Portainer 集成配置。

##### `integrations.portainer.enabled` (必需)

- **类型**: 布尔值
- **说明**: 是否将集群注册到 Portainer（Edge Agent 模式）
- **推荐**: 业务集群设为 `true`，devops 集群设为 `false`

##### `integrations.portainer.tags` (可选)

- **类型**: 字符串数组
- **说明**: Portainer 环境标签，用于分组和筛选
- **示例**: `["dev", "k3d", "business"]`

#### `integrations.haproxy` (必需)

HAProxy 集成配置。

##### `integrations.haproxy.enabled` (必需)

- **类型**: 布尔值
- **说明**: 是否为集群添加 HAProxy 路由
- **推荐**: 业务集群设为 `true`，devops 集群设为 `false`

#### `integrations.argocd` (必需)

ArgoCD 集成配置。

##### `integrations.argocd.enabled` (必需)

- **类型**: 布尔值
- **说明**: 是否将集群注册到 ArgoCD
- **推荐**: 业务集群设为 `true`，devops 集群设为 `false`

##### `integrations.argocd.labels` (可选)

- **类型**: 键值对对象
- **说明**: ArgoCD cluster secret 的标签，用于 ApplicationSet 筛选
- **示例**:
  ```yaml
  labels:
    env: dev
    provider: k3d
    type: business
  ```

## 配置模板

### k3d 集群（独立子网）

```yaml
version: v1
cluster:
  provider: k3d
network:
  http_port: 18090
  https_port: 18443
  node_port: 30080
  pf_port: 19001
  subnet: "10.101.0.0/16"  # 独立子网
integrations:
  portainer:
    enabled: true
    tags: ["dev", "k3d"]
  haproxy:
    enabled: true
  argocd:
    enabled: true
    labels:
      env: dev
      provider: k3d
      type: business
```

### kind 集群（共享网络）

```yaml
version: v1
cluster:
  provider: kind
network:
  http_port: 18091
  https_port: 18444
  node_port: 30080
  pf_port: 19002
  subnet: ""               # 空字符串，使用共享 kind 网络
integrations:
  portainer:
    enabled: true
    tags: ["dev", "kind"]
  haproxy:
    enabled: true
  argocd:
    enabled: true
    labels:
      env: dev
      provider: kind
      type: business
```

### devops 管理集群（k3d 共享网络）

```yaml
version: v1
cluster:
  provider: k3d
network:
  http_port: 23800
  https_port: 23843
  node_port: 30800
  pf_port: 19000
  subnet: ""               # 空字符串，使用 k3d-shared 网络
integrations:
  portainer:
    enabled: false         # devops 集群不注册到 Portainer
  haproxy:
    enabled: false         # devops 服务直接通过 NodePort 访问
  argocd:
    enabled: false         # devops 集群是 ArgoCD 的宿主
```

## 端口分配建议

### HAProxy 端口（宿主机暴露）

- **devops**: 23800 (HTTP), 23843 (HTTPS)
- **业务集群**: 18090-18099 (HTTP), 18443-18499 (HTTPS)

### NodePort（集群内部）

- **devops**: 30800-30850
- **业务集群**: 30080（统一使用）

### Port-forward 端口（调试）

- **devops**: 19000
- **业务集群**: 19001-19099

### 子网分配（k3d 独立子网）

- **k3d-shared**: 172.18.0.0/16（devops + HAProxy + Portainer）
- **业务集群**: 10.101.0.0/16, 10.102.0.0/16, 10.103.0.0/16, ...

## 配置验证

创建配置文件后，可以使用以下工具验证：

```bash
# 验证 YAML 语法
yamllint .kindler.yaml

# 验证配置完整性（使用 Kindler 内置工具）
bash scripts/lib_config.sh validate .kindler.yaml
```

## 配置文件生命周期

1. **创建**: 使用 `scripts/init_env_branch.sh` 初始化环境分支时自动生成
2. **修改**: 直接编辑文件后 commit & push 到 Git
3. **应用**: `scripts/create_env.sh --git-mode` 读取配置创建集群
4. **删除**: 删除环境分支时自动清理

## 最佳实践

1. **端口不重复**: 确保 `http_port` 和 `https_port` 在所有环境中唯一
2. **子网不冲突**: k3d 集群的 `subnet` 不能重叠
3. **标签规范**: Portainer tags 和 ArgoCD labels 使用统一命名规范
4. **版本控制**: 所有配置变更通过 Git commit 记录
5. **最小配置**: 可选字段不使用时保持默认值或留空

## 相关文档

- [Git Branching Strategy](./GIT_BRANCHING_STRATEGY.md)
- [Network Architecture](./NETWORK_ARCHITECTURE.md)
- [ArgoCD Integration](./ARGOCD_INTEGRATION.md)


