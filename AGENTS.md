# Repository Guidelines

本仓库用于维护本地轻量级环境与容器编排：以 Portainer CE 统一管理容器/轻量级集群（kind/k3d 可选），HAProxy 提供统一入口。目标：简单、快速、够用。

## 部署拓扑

### 核心架构
```
┌─────────────────────────────────────────────────────────────┐
│ HAProxy (haproxy-gw)                                        │
│ - 统一网络入口 (192.168.51.30)                             │
│ - 端口暴露:                                                 │
│   * 23343: Portainer HTTPS                                  │
│   * 23380: Portainer HTTP (重定向到 23343)                 │
│   * 23800: ArgoCD (devops 集群)                            │
│   * 23080: 各业务集群 NodePort 路由（基于域名）           │
└─────────────────────────────────────────────────────────────┘
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
           │        - Ingress: argocd.devops.local
           │        - 通过 HAProxy 23800 端口暴露
           │
           └──> 业务集群 (k3d/kind, 按需创建)
                - 通过 create_env.sh 创建
                - 自动注册到 Portainer (Edge Agent)
                - 自动注册到 ArgoCD (kubectl 方式)
                - 通过 HAProxy 23080 + 域名路由访问
```

### 核心组件
1. **HAProxy**: 统一入口网关，所有外部访问的唯一入口
2. **Portainer CE**: 容器和集群统一管理界面
3. **devops 集群**: 管理集群，运行 ArgoCD 等 DevOps 工具
4. **业务集群**: 运行实际应用的 k3d/kind 集群

### 网络拓扑
- HAProxy 连接到所有 k3d 集群网络（通过 `docker network connect`）
- Portainer 通过 Edge Agent 模式与业务集群通信
- ArgoCD 通过 ServiceAccount token 连接业务集群 API Server

### 生命周期管理
- `clean.sh`: 清理所有环境（集群、容器、网络、数据）
- `bootstrap.sh`: 拉起基础设施（HAProxy + Portainer + devops 集群 + ArgoCD）
- `create_env.sh`: 创建业务集群并自动注册到 Portainer 和 ArgoCD
- `delete_env.sh`: 删除业务集群并自动注销 Portainer 和 ArgoCD 注册

## 语言与沟通
- 文档与日常交流默认使用中文。
- 专业术语、命令、目录路径、代码标识符保留英文原样（如 `k3d`, `Dockerfile`, `kubectl apply`).
- 提交信息与 PR 标题可用中文，但遵循 Conventional Commits 英文前缀（如 `feat:`, `fix:`）。
- 面向外部社区或上游同步时，可附英文摘要（可选）。

## 项目结构与模块组织
- 目录（按需创建）：
  - `images/`：各镜像的 Dockerfile 与构建上下文（如 `images/base/`）。
  - `clusters/`：k3d 集群配置（`*.yaml`）及默认值。
  - `compose/`：Docker Compose（`compose/portainer/`、`compose/haproxy/`）。
  - `manifests/`：Kubernetes YAML（按需使用）。
  - `scripts/`：辅助脚本；尽量保持 POSIX‑sh 兼容。
  - `examples/`：最小可运行示例。
  - `config/`：环境与密钥（如 `clusters.env`、`secrets.env`）。

## 构建、测试与开发命令
- 启动 Portainer：`scripts/portainer.sh up`（读取 `config/secrets.env` 中 `PORTAINER_ADMIN_PASSWORD`，使用命名卷 `portainer_portainer_data`/`portainer_secrets` 持久化）
- 启动 HAProxy：`docker compose -f compose/haproxy/docker-compose.yml up -d`（对外 `23380/23343` 暴露 Portainer；`23080` 反代各集群 NodePort）
- 创建集群：`scripts/create_env.sh -n <env> [-p kind|k3d] [--node-port <port>] [--pf-port <port>] [--register-portainer|--no-register-portainer] [--haproxy-route|--no-haproxy-route]`
  - 默认参数来自 `config/environments.csv`，命令行可覆盖。
  - CSV 列：`env,provider,node_port,pf_port,register_portainer,haproxy_route,http_port,https_port`
  - 版本镜像可通过 `config/clusters.env` 配置：`KIND_NODE_IMAGE`（默认 `kindest/node:v1.31.12`）、`K3D_IMAGE`（默认 `rancher/k3s:stable`）。
- 同步路由：`scripts/haproxy_sync.sh [--prune]`；基础测试：`bats tests`（若安装了 bats）

访问示例：
- Portainer：`http://192.168.51.30:23380` → 301 到 `https://192.168.51.30:23343`
- ArgoCD：`http://192.168.51.30:23800/` (admin / secrets.env 中配置的密码)

## 编码风格与命名规范
- Dockerfile/YAML：两空格缩进；建议行宽 ~100 列。
- Bash/sh：脚本顶部使用 `set -Eeuo pipefail` 与 `IFS=$'\n\t'`。
- 命名：目录用 `lower-kebab/`；脚本用 `snake_case.sh`；Kubernetes 对象用 `lower-kebab`。
- 格式化/静态检查：`shfmt -w`、`shellcheck`、`yamllint`、`hadolint`。

## 测试指南
- Shell 脚本：在 `tests/` 添加 `bats` 用例；覆盖端口与健康检查。
- 入口验证：
  - Portainer：`curl -kI https://192.168.51.30:23343` 为 `200`；`curl -I http://192.168.51.30:23380` 为 `301`。
- 轻量集群：按需用 `kubectl get nodes --context <ctx>` 做冒烟校验。

## 提交与 Pull Request 规范
- 使用 Conventional Commits：`feat:`、`fix:`、`chore:`、`docs:`、`ci:`、`refactor:`。
- 提交应小而聚焦；说明“为什么”而不仅是“做了什么”。
- PR 必须包含：动机、变更摘要、测试方法（命令）、必要的截图/日志，并关联相关 issue。

## 安全与配置提示
- 禁止提交密钥；提供 `*.example` 文件，并在 `.gitignore` 忽略真实值。
- 尽量使用镜像摘要固定基镜像；避免在生产路径使用 `latest`。
- 配置以环境变量为主，避免硬编码；记录必需变量。

## Agent 专用说明
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