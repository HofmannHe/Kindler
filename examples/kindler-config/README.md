# Kindler 配置示例

本目录包含 `.kindler.yaml` 配置文件的示例。

## 文件列表

- `.kindler.yaml` - k3d 集群配置示例（独立子网）
- `kind-example.yaml` - kind 集群配置示例（共享网络）
- `devops-example.yaml` - devops 管理集群配置示例

## 使用方法

### 1. 作为模板使用

复制示例文件到您的环境分支：

```bash
# 假设您要创建 env/myenv 分支
git checkout -b env/myenv
cp examples/kindler-config/.kindler.yaml .
# 编辑配置
vi .kindler.yaml
# 提交
git add .kindler.yaml
git commit -m "feat: add myenv configuration"
git push origin env/myenv
```

### 2. 通过脚本初始化

使用 Kindler 提供的初始化脚本：

```bash
# 自动创建分支并生成配置
bash tools/git/init_env_branch.sh -n myenv -p k3d \
  --http-port 19100 --https-port 19200 \
  --subnet 10.104.0.0/16
```

### 3. 创建集群

使用 Git 模式创建集群：

```bash
# 从 Git 分支读取配置创建集群
bash scripts/create_env.sh -n myenv --git-mode

# 或者一条命令完成（初始化分支 + 创建集群）
bash scripts/create_env.sh -n myenv -p k3d \
  --git-mode --init-branch \
  --http-port 19100 --https-port 19200 \
  --subnet 10.104.0.0/16
```

## 配置要点

### 端口配置

- **http_port / https_port**: 必须在所有环境中唯一
- **node_port**: 通常使用 30080（集群内统一）
- **pf_port**: 调试端口，建议递增分配

### 网络配置

#### k3d 集群

- **独立子网**: 设置 `subnet` 为 `10.x.0.0/16` 格式
- **共享网络**: 设置 `subnet` 为空字符串 `""`（用于 devops）

#### kind 集群

- 始终使用共享 `kind` 网络
- `subnet` 字段无效，应设为 `""`

### 集成配置

#### Portainer

- 业务集群: `enabled: true`
- devops 集群: `enabled: false`
- `tags`: 用于环境分组

#### HAProxy

- 业务集群: `enabled: true`（通过域名访问服务）
- devops 集群: `enabled: false`（直接 NodePort）

#### ArgoCD

- 业务集群: `enabled: true`（应用自动部署）
- devops 集群: `enabled: false`（ArgoCD 宿主）
- `labels`: 用于 ApplicationSet 筛选

## 参考文档

- [配置文件规范](../../docs/KINDLER_CONFIG_SPEC.md)
- [Git 分支策略](../../docs/GIT_BRANCHING_STRATEGY.md)
- [网络架构](../../docs/NETWORK_ARCHITECTURE.md)

