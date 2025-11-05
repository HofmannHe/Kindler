# Project Context

## Purpose
面向本地与轻量化环境的一体化编排与管理：以 Portainer CE 统一管理容器与集群（包含业务集群的 Edge Agent 注册与生命周期），以 HAProxy 提供统一网络入口与域名路由；提供一个“简单、快速、够用”的 GitOps 驱动最小基准（devops 管理集群 + 业务集群），并通过脚本与 WebUI（FastAPI 后端）实现自动化创建/删除、注册、路由与健康校验。

## Tech Stack
- Docker / Docker Compose
- Portainer CE（Edge Agent 模式）
- HAProxy（统一入口与域名路由）
- k3d / kind（轻量级 Kubernetes 集群）
- Traefik（Ingress Controller，随集群初始化）
- ArgoCD + ApplicationSet（GitOps 持续交付）
- Bash/sh（POSIX 兼容脚本工具集）
- SQLite（WebUI 后端内置数据库，唯一数据源）
- FastAPI + Uvicorn（WebUI 后端），前端静态站点（Nginx）

## Project Conventions

### Code Style
- Bash/sh：脚本顶部使用 `set -Eeuo pipefail` 与 `IFS=$'\n\t'`；尽量 POSIX‑sh 兼容。
- YAML/Dockerfile：两空格缩进，建议行宽 ~100 列；避免 `latest`，优先镜像摘要/固定版本。
- 命名：目录 `lower-kebab/`；脚本 `snake_case.sh`；Kubernetes 对象 `lower-kebab`；域名遵循 `service.env.BASE_DOMAIN`。
- 配置优先环境变量，不硬编码；必须提供 `*.example` 并在 `.gitignore` 忽略真实值。
- 静态检查/格式化：`shfmt -w`、`shellcheck`、`yamllint`、`hadolint`。

### Architecture Patterns
- 核心：`HAProxy` 作为唯一入口；`Portainer CE` 作为容器/集群统一管理；`devops` 管理集群运行 `ArgoCD` 与工具服务；业务集群按需创建（k3d/kind）。
- GitOps：外部 Git 仓库托管应用；`ApplicationSet` 以“分支=环境”映射动态生成 `Application` 并自动部署。
- 数据一致性：`SQLite`（`/data/kindler-webui/kindler.db`）为唯一真实数据源；`bootstrap.sh` 幂等初始化表结构与 CSV 导入；脚本与 WebUI 共享访问，带 `flock` 文件锁保障并发安全。
- 环境隔离：强制 Git worktree + `KINDLER_NS` 命名空间后缀，避免影响主分支运行环境。
- 网络：HAProxy 连接各集群 Docker 网络；业务入口统一经 80（HTTP）/443（透传 Portainer HTTPS）。

### Testing Strategy
- 脚本测试：`tests/*.bats` + 辅助 Shell 测试（HAProxy 配置、端口与健康检查、ApplicationSet）
- 冒烟/验收：`scripts/smoke.sh <env>`；要求 `curl` 验证 Portainer 301→HTTPS 与服务 200；记录到 `docs/TEST_REPORT.md`。
- WebUI：后端接口与并发/可见性/端到端脚本测试（`tests/webui_*.sh`）。
- 规范性：提供 `scripts/check_gitops_compliance.sh` 确保“除 ArgoCD 自身外，所有应用由 ArgoCD 管理”。
- 验收流程（每轮修改的强制标准）：
  1) 执行 `clean.sh` 后 `bootstrap.sh` 拉起基础集群；
  2) 使用 `create_env.sh` 创建 `environments.csv` 中的环境（kind≥3，k3d≥3）；
  3) 确认集群可被 Portainer 管理，全程无报错与警告。

### Git Workflow
- 根目录仅承载 `master/main` 稳定分支；开发与测试必须在 `worktrees/` 目录下的 Git worktree 进行。
- 运行脚本前设置 `KINDLER_NS=<ns>`（建议与分支名一致）；所有实际资源（集群名、HAProxy 路由、ArgoCD Secret/应用等）会追加命名空间后缀。
- 清理使用 `scripts/clean_ns.sh`（只清理 `KINDLER_NS` 对应资源），禁止在开发分支运行根目录 `clean.sh`。
- 提交遵循 Conventional Commits（`feat:`、`fix:`、`docs:` 等），提交信息应说明“为什么”。

## Domain Context
- 域名规则：`[service].[env].[BASE_DOMAIN]`，系统保留 `devops` 作为管理环境；示例：`portainer.devops.$BASE_DOMAIN`、`haproxy.devops.$BASE_DOMAIN/stat`、`argocd.devops.$BASE_DOMAIN`、`whoami.<env>.$BASE_DOMAIN`。
- devops 集群仅承载管理服务（如 ArgoCD），不部署业务示例（如 whoami）。
- GitOps：分支名与环境名一一对应（`dev`/`uat`/`prod`/`dev-k3d` 等）。`ApplicationSet` 按“环境 → 分支”渲染 Helm 参数（如 Ingress host）。
- HAProxy：为每个业务集群添加动态 ACL/后端，路由到集群的 Traefik NodePort；自动连接 k3d/kind Docker 网络。
- WebUI：声明式 API 将期望状态写入 SQLite，宿主机 `reconciler` 周期性对齐实际状态（调用同一套 `scripts/*`）。

## Important Constraints
- 安全：禁止提交密钥；仅提交 `*.example`；真实值置于本地 `config/`。
- GitOps 合规：除 ArgoCD 本身外，禁止 `kubectl apply` 直接部署；配置变更必须经 Git 提交触发。
- 数据源：CSV 仅在 `bootstrap.sh` 初始化时导入；创建/删除/同步操作以 SQLite 为准（不可用时可回退）。
- 最小变更原则：建立最小可用基准后，非必要不变更；避免破坏性命令与硬编码环境名（测试需覆盖环境名增删改）。
- 接口统一：通过 `scripts/*` 入口暴露操作，不新增 Makefile 目标。

## Git 仓库说明

**重要**：项目使用两个 Git 仓库，用途不同：

### 1. GitHub 代码仓库（本仓库）
- **地址**: https://github.com/HofmannHe/Kindler/
- **用途**: 存放项目代码、脚本、配置、文档
- **分支策略**: main 为稳定分支，特性开发使用 worktree
- **推送**: 通过 PR 合并到 main

### 2. GitOps 应用仓库
- **地址**: 由用户在 `config/git.env` 中配置（如 `git.devops.192.168.51.30.sslip.io/fc005/devops.git`）
- **用途**: 存放业务集群的应用配置（如 whoami 的 Kubernetes manifests）
- **分支策略**: 分支名与集群名一一对应（dev/uat/prod 等）
- **访问**: 通过 HAProxy 提供统一入口（隔离环境差异）
- **同步**: ArgoCD 监听此仓库，ApplicationSet 动态生成 Applications

**注意**: 不要混淆这两个仓库。代码变更提交到 GitHub，应用配置由脚本自动同步到 GitOps 仓库。

## External Dependencies
- 外部 GitOps 仓库（`config/git.env` 配置 `GIT_REPO_URL`），存放应用配置，由 ArgoCD 监听
- GitHub（代码仓库，本项目托管地）
- Docker / Docker Compose（Portainer 与 HAProxy 运行时）
- k3d / kind / kubectl（轻量集群与 CLI）
- ArgoCD（管理集群内），ApplicationSet Controller
- sslip.io（默认 `BASE_DOMAIN` 示例解析）、Traefik（Ingress）
- Bats / curl / jq / shfmt / shellcheck / yamllint / hadolint（测试与校验）
