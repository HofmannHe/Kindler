# Repository Guidelines

本仓库用于维护本地轻量级环境与容器编排：以 Portainer CE 统一管理容器/轻量级集群（kind/k3d 可选），HAProxy 提供统一入口。目标：简单、快速、够用。

## 部署拓扑

### 核心架构
```
┌────────────────────────────────────────────────────────────────┐
│ HAProxy (haproxy-gw)                                           │
│ - 统一网络入口 (192.168.51.30)                                │
│ - 端口暴露:                                                    │
│   *  80 : 域名统一入口（Portainer HTTP→HTTPS、ArgoCD、业务）     │
│   * 443: Portainer HTTPS 透传                                 │
└────────────────────────────────────────────────────────────────┘
           │
           ├──> Portainer CE (portainer-ce)
           │    - Docker Compose 部署
           │    - 管理所有容器和集群
           │    - Edge Agent 模式注册业务集群
           │
           ├──> devops 集群 (k3d)
           │    - 端口映射: 10800:80, 10843:443, 10091:6443
           │    - 内置 Traefik Ingress Controller
           │    - 服务:
           │      * ArgoCD v3.1.7 (GitOps CD 工具)
           │        - 管理所有业务集群的应用部署
           │        - ApplicationSet 动态生成 Applications
           │        - Ingress: argocd.devops.$BASE_DOMAIN
           │      * 外部 Git 仓库（通过 config/git.env 配置）
           │        - 存储应用代码仓库 (如 whoami)
           │        - ArgoCD 监听 Git 变化自动部署
           │    - 全部通过 HAProxy 80 端口基于域名暴露
           │
           └──> 业务集群 (k3d/kind, 按需创建)
                - 通过 create_env.sh 创建
                - 自动注册到 Portainer (Edge Agent)
                - 自动注册到 ArgoCD (kubectl 方式)
                - 通过 HAProxy 80 + 域名路由访问
                - whoami 应用通过 GitOps 自动部署
```

### 核心组件
1. **HAProxy**: 统一入口网关，所有外部访问的唯一入口
2. **Portainer CE**: 容器和集群统一管理界面
3. **devops 集群**: 管理集群，运行 ArgoCD、PostgreSQL、pgAdmin 等 DevOps 和 PaaS 服务
4. **业务集群**: 运行实际应用的 k3d/kind 集群
5. **PaaS 服务**: PostgreSQL 和 pgAdmin 部署在 devops 集群，供所有业务集群使用

### GitOps 工作流
- **外部 Git 服务**: 托管应用代码（在 `config/git.env` 中配置）
- **ArgoCD**: 监听 Git 仓库变化，自动部署到集群
- **ApplicationSet**: 从 `config/environments.csv` 动态生成 Applications
- **分支映射**: 分支名与环境名一一对应（如 `dev`、`uat`、`prod`、`dev-k3d` 等），ArgoCD 将分支 `<env>` 的代码同步到集群 `<env>`
- **示例应用**: whoami (仅域名差异，遵循最小化差异原则)

### 网络拓扑
- HAProxy 连接到所有 k3d 集群网络（通过 `docker network connect`）
- Portainer 通过 Edge Agent 模式与业务集群通信
- ArgoCD 通过 ServiceAccount token 连接业务集群 API Server

### 生命周期管理

#### devops 集群（管理集群）
- **创建**: 通过 `bootstrap.sh` 创建，包含 HAProxy、Portainer、ArgoCD、PostgreSQL、pgAdmin
- **清理**: 默认不清理，需要 `clean.sh --all` 或 `clean.sh --include-devops` 才会清理
- **说明**: devops 集群是管理集群，存储所有业务集群的配置和状态，通常保持运行

#### 业务集群
- **创建**: `create_env.sh -n <name> -p kind|k3d` - 自动注册到 Portainer（Edge Agent）和 ArgoCD
- **删除**: `delete_env.sh <name>` - 自动反注册，清理所有相关资源
- **停止**: `stop_env.sh <name>` - 停止集群但保留配置（临时释放资源）
- **启动**: `start_env.sh <name>` - 启动已停止的集群

#### 完整清理
- `clean.sh`: 清理所有业务集群，保留 devops 集群
- `clean.sh --all`: 清理所有环境（包括 devops 集群、容器、网络、数据）

## 语言与沟通
- 文档与日常交流默认使用中文。
- 专业术语、命令、目录路径、代码标识符保留英文原样（如 `k3d`, `Dockerfile`, `kubectl apply`).
- 提交信息与 PR 标题可用中文，但遵循 Conventional Commits 英文前缀（如 `feat:`, `fix:`）。
- 面向外部社区或上游同步时，可附英文摘要（可选）。

## 项目结构与模块组织
- 目录（按需创建）：
  - `images/`：各镜像的 Dockerfile 与构建上下文（如 `images/base/`）。
  - `clusters/`：k3d 集群配置（`*.yaml`）及默认值。
  - `compose/`：Docker Compose（`compose/infrastructure/` 包含 Portainer 与 HAProxy）。
  - `manifests/`：Kubernetes YAML（按需使用）。
  - `scripts/`：辅助脚本；尽量保持 POSIX‑sh 兼容。
  - `examples/`：最小可运行示例。
  - `config/`：环境与密钥（如 `clusters.env`、`secrets.env`）。

## 构建、测试与开发命令
- 启动 Portainer：`scripts/portainer.sh up`（读取 `config/secrets.env` 中 `PORTAINER_ADMIN_PASSWORD`，使用命名卷 `portainer_portainer_data`/`portainer_secrets` 持久化）
- 启动 HAProxy：`docker compose -f compose/infrastructure/docker-compose.yml up -d`（默认对外 `80/443`，可通过 `HAPROXY_HTTP_PORT`/`HAPROXY_HTTPS_PORT` 调整）
- 创建集群：`scripts/create_env.sh -n <env> [-p kind|k3d] [--node-port <port>] [--pf-port <port>] [--register-portainer|--no-register-portainer] [--haproxy-route|--no-haproxy-route]`
  - 默认参数来自 `config/environments.csv`，命令行可覆盖。
  - CSV 列：`env,provider,node_port,pf_port,register_portainer,haproxy_route,http_port,https_port`
  - 版本镜像可通过 `config/clusters.env` 配置：`KIND_NODE_IMAGE`（默认 `kindest/node:v1.31.12`）、`K3D_IMAGE`（默认 `rancher/k3s:stable`）。
- 同步路由：`scripts/haproxy_sync.sh [--prune]`；基础测试：`bats tests`（若安装了 bats）

访问示例：
- Portainer：`http://portainer.devops.$BASE_DOMAIN` → 301 跳转到 `https://portainer.devops.$BASE_DOMAIN`
- ArgoCD：`http://192.168.51.30:23800/` (admin / secrets.env 中配置的密码)

## 编码风格与命名规范
- Dockerfile/YAML：两空格缩进；建议行宽 ~100 列。
- Bash/sh：脚本顶部使用 `set -Eeuo pipefail` 与 `IFS=$'\n\t'`。
- 命名：目录用 `lower-kebab/`；脚本用 `snake_case.sh`；Kubernetes 对象用 `lower-kebab`。
- 格式化/静态检查：`shfmt -w`、`shellcheck`、`yamllint`、`hadolint`。

## 测试指南
- Shell 脚本：在 `tests/` 添加 `bats` 用例；覆盖端口与健康检查。
- 入口验证：
  - Portainer：`curl -kI https://portainer.devops.$BASE_DOMAIN` 为 `200`；`curl -I http://portainer.devops.$BASE_DOMAIN` 为 `301`。
- 轻量集群：按需用 `kubectl get nodes --context <ctx>` 做冒烟校验。

## 提交与 Pull Request 规范
- 使用 Conventional Commits：`feat:`、`fix:`、`chore:`、`docs:`、`ci:`、`refactor:`。
- 提交应小而聚焦；说明“为什么”而不仅是“做了什么”。
- PR 必须包含：动机、变更摘要、测试方法（命令）、必要的截图/日志，并关联相关 issue。

## 安全与配置提示
- 禁止提交密钥；提供 `*.example` 文件，并在 `.gitignore` 忽略真实值。
- `config/git.env` 仅保存本地仓库凭证，请使用 `config/git.env.example` 模板并避免提交真实值。
- 尽量使用镜像摘要固定基镜像；避免在生产路径使用 `latest`。
- 配置以环境变量为主，避免硬编码；记录必需变量。

## Agent 专用说明
- 域名命名统一遵循 `[service].[env].[BASE_DOMAIN]` 规则；系统保留集群使用 `devops` 作为 env，例如 `portainer.devops.192.168.51.30.sslip.io`、`haproxy.devops.192.168.51.30.sslip.io/stat`、`argocd.devops.192.168.51.30.sslip.io`、`whoami.devk3d.192.168.51.30.sslip.io`。
- 每次修改后必须验证：至少使用 curl（必要时配合浏览器/MCP 浏览器）验证基础环境与域名路由；并运行 `scripts/smoke.sh <env>` 记录到 `docs/TEST_REPORT.md`（强制要求）。
- 遵循本 AGENTS.md 对其目录树内文件的要求。
- 提前给出简短计划，保持改动最小，避免破坏性命令。
- 对改动文件执行格式化/静态检查；统一通过 `scripts/*` 入口脚本暴露操作，避免新增 Makefile 目标。
- 项目目标是创建一个Portainer+HAProxy为核心的基础环境，然后根据用户提供的配置清单拉起指定的环境，拉起的环境需要被基础环境的Portainer管理，且在HAProxy中为其创建了路由，便于用户访问其中的服务
- 每轮修改都需要遵循以下验收标准：
1. 先执行clean.sh，然后执行bootstrap.sh拉起基础集群
2. 执行create_env.sh,创建environments.csv中的虚拟环境，其中kind至少三个，k3d至少三个
3. 确保拉起的集群功能正常，能被portainer管理，且全程无报错和警告
- 已经确认Edge Agent适合当前模式，注意不要又反复退回去尝试普通Agent
- 当最小基准建立之后，要严格遵循最小变更原则，非必要不变更
- 每次修订README等文档的时候需要同时修订中英文版本
- devops集群不应该部署whoami服务，应该部署到其它业务集群上。另外注意这些集群名称包括域名不应存在硬编码，因为环境配置csv中的环境名称是可能增删改的，测试用例也需要覆盖环境名增删改

### 分支与工作树（强制要求）
- 根目录仅用于 `master/main` 稳定分支，供实际部署与用户使用；禁止在根目录直接开发或推送（master 为保护分支，仅允许通过 PR 合并）。
- 所有开发与测试必须在 `worktrees/` 目录下的 git worktree 中进行：每个子目录代表一个开发分支。
- 环境隔离：开发分支下运行脚本前必须设置 `KINDLER_NS=<ns>`（建议与分支名一致，例如 `develop`）。脚本会将实际资源（集群名、HAProxy 路由、ArgoCD secret/应用等）添加命名空间后缀，避免影响 master 运行环境。
- 清理：在开发分支不要运行根目录的 `clean.sh`（会影响全局）。使用 `scripts/clean_ns.sh`，它只清理 `KINDLER_NS` 对应的资源。
- 建议流程：
  ```bash
  mkdir -p worktrees
  git worktree add worktrees/develop develop
  cd worktrees/develop
  export KINDLER_NS=develop
  ./scripts/create_env.sh -n dev
  # ... 开发与验证 ...
  ./scripts/clean_ns.sh --from-csv   # 仅清理 develop 命名空间下的资源
  ```

## 开发模式（Git Flow + Git Worktree）

- 目标：实现“部署与开发隔离”。项目根目录仅承载 `master`（或 `main`）稳定分支，供用户直接使用与部署；开发分支使用 `git worktree` 挂载到本地 `worktrees/` 目录下。
- 目录规范：
  - 在项目根目录创建 `worktrees/`（已加入 `.gitignore`），该目录不纳入版本控制。
  - `worktrees/<branch-name>/` 对应一个开发分支的工作树。
- 使用示例：
  ```bash
  # 准备本地工作树根目录（已在 .gitignore 中忽略）
  mkdir -p worktrees

  # 创建并挂载新特性分支（基于 master/main）
  git worktree add worktrees/feature-x feature/x

  # 切换到工作树开发
  cd worktrees/feature-x
  # 开发、提交、推送...

  # 回到主仓部署目录（master/main），不受工作树改动影响
  cd ../../  # 返回项目根目录

  # 完成后移除工作树
  git worktree remove worktrees/feature-x
  git branch -D feature/x   # 如需删除分支
  ```
- 约束：
  - 所有部署脚本、CI/测试不得依赖 `worktrees/` 内容；生产使用始终以根目录的 `master/main` 为准。
  - 文档/脚本若需说明开发流程，统一指向 `git worktree` 方式；避免在根目录创建临时开发文件。

## GitOps 合规要求

### 核心原则
- **除 ArgoCD 本身外，所有 Kubernetes 应用必须由 ArgoCD 管理**
- **禁止使用 `kubectl apply` 直接部署应用**（ArgoCD 安装除外）
- **配置变更必须通过 Git 提交触发**

### 合规检查
- 所有应用部署必须有对应的 ArgoCD Application 或 ApplicationSet
- 应用配置存储在外部 Git 仓库（`config/git.env` 配置）
- 使用 `scripts/check_gitops_compliance.sh` 检查合规性

### 例外情况
- ArgoCD 本身的安装和配置（通过 `scripts/setup_devops.sh`）
- 临时调试用途（需在调试完成后清理）

## PaaS 服务规范

### PostgreSQL
- **部署位置**: devops 集群的 `paas` namespace
- **用途**: 存储集群配置信息（clusters 表）
- **访问方式**: 集群内通过 `postgresql.paas.svc.cluster.local:5432`
- **管理方式**: 由 ArgoCD 管理，配置存储在外部 Git 仓库

### pgAdmin
- **部署位置**: devops 集群的 `paas` namespace
- **访问地址**: `https://pgadmin.devops.192.168.51.30.sslip.io`
- **用途**: PostgreSQL 数据库管理界面
- **管理方式**: 由 ArgoCD 管理，通过 Traefik Ingress 暴露

### 集群配置管理
- **优先级**: PostgreSQL > CSV 文件
- **回退机制**: 数据库不可用时自动使用 `config/environments.csv`
- **数据同步**: 创建/删除集群时自动更新数据库记录
- **迁移工具**: `scripts/migrate_csv_to_db.sh` 用于一次性迁移
