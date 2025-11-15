# FILE_INVENTORY（根目录文件清单）

> 本清单用于管理仓库**根目录下的长期存在文件与顶层子目录**，配合各子目录内的 `FILE_INVENTORY.md` / `README` / `FILE_PLAN.md` 共同形成一棵自顶向下的“文件清单树”。  
> 具体规则：
> - 本文件只关心：根目录直接包含的 Markdown 文档、结构性清单（如 `FILE_PLAN.md`、`FILE_INVENTORY_ALL.md`）以及顶层子目录的角色说明。
> - 更深层结构由对应子目录下的 `FILE_INVENTORY.md` / README 等接力描述（例如：`docs/FILE_INVENTORY.md`、`examples/FILE_INVENTORY.md`、`webui/FILE_INVENTORY.md`、`tools/FILE_INVENTORY.md`）。
> - 全局严格白名单仍由 `FILE_INVENTORY_ALL.md` 提供，`scripts/file_inventory_all.sh --check` 会验证其与 `git ls-files` 一致。

## 字段说明

- `Path`：文件或目录相对于仓库根目录的路径。
- `Type`：类别，例如：`overview` / `architecture` / `testing-guide` / `changelog` / `inventory` / `module` / `infra` / `spec` 等。
- `Audience`：目标读者，例如：`developer` / `operator` / `user` / `reviewer` / `AI`。
- `Scope`：责任边界，说明该条目“负责什么、不负责什么”，尽量一句话说清楚。
- `Status`：当前状态，建议值：`authoritative`（唯一权威）/ `primary`（主要参考）/ `supporting`（辅助说明）。

## 根目录文件

| Path                  | Type          | Audience            | Scope                                                                                          | Status        |
|-----------------------|---------------|---------------------|-------------------------------------------------------------------------------------------------|---------------|
| `README.md`           | overview      | developer, user     | 项目总体介绍与快速上手入口，不展开架构/测试细节；其它文档应从此入口被发现。                   | authoritative |
| `README_CN.md`        | overview      | developer, user     | README 中文版，保持与 `README.md` 内容同步。                                                   | authoritative |
| `README_EN.md`        | overview      | developer, user     | README 英文版，保持与 `README.md` 内容在语义上同步，供英文读者参考。                           | authoritative |
| `AGENTS.md`           | process       | developer, AI       | 面向 Agent/贡献者的操作约束与开发模式说明，不重复 README 内容。                               | authoritative |
| `CLAUDE.md`           | process       | developer, AI       | 指向 `AGENTS.md` 的兼容性入口，面向基于 CLAUDE 工具链的 Agent 使用，不新增独立语义。          | supporting    |
| `ARCHITECTURE.md`     | architecture  | developer, reviewer | 顶层架构总览，描述核心组件关系与数据流，不替代更细粒度的设计/实现文档。                       | primary       |
| `README_TESTING.md`   | testing-guide | developer, reviewer | 测试总览与入口说明，引用 `docs/REGRESSION_TEST_PLAN.md` 与 `tests/` 入口脚本。                 | primary       |
| `README_RECONCILER.md`| operations    | developer, operator | Reconciler 行为与使用说明，不覆盖整体架构；与 `ARCHITECTURE.md` 协同。                        | primary       |
| `CHANGELOG.md`        | changelog     | developer, reviewer | 记录基础设施与脚本的主要变更历史，帮助理解版本间差异，不替代详细设计与规格文档。             | primary       |
| `CHANGELOG_WEBUI.md`  | changelog     | developer, reviewer | 记录 WebUI 相关变更历史，聚焦前端/后端与集成层面的变更。                                     | primary       |
| `FILE_PLAN.md`        | inventory     | developer, reviewer | 顶层目录级规划，描述根目录各子目录的角色与边界，是文件清单树的“目录视图”。                   | authoritative |
| `FILE_INVENTORY.md`   | inventory     | developer, reviewer | 本文件，用于描述根目录文件与顶层子目录角色，是 FILE_INVENTORY 清单树的根节点。               | authoritative |
| `FILE_INVENTORY_ALL.md` | inventory   | developer, reviewer | 基于 `git ls-files` 的全局严格白名单，仅做文件级审计，具体用途/边界由本清单与子树清单解释。 | authoritative |
| `LICENSE`             | process       | developer, user     | 代码与文档的许可证信息，不承担架构/流程说明职责。                                             | primary       |
| `.gitignore`          | config        | developer           | Git 忽略规则，控制哪些文件不会被纳入版本控制或 FILE_INVENTORY_ALL 清单。                      | primary       |
| `.cursorrules`        | config        | developer, AI       | 开发工具（如 Cursor）使用的工程规则与约束，不替代 AGENTS/openspec 规范。                      | supporting    |
| `verify_deployment.sh`| script        | developer, operator | 顶层部署校验脚本入口，行为由 `scripts/` 目录脚本与文档约束，不在此展开。                     | supporting    |

> 说明：其它根目录下的 `.log` 文件（如回归测试输出）视为历史调试产物，按 `reduce-report-noise` 约束优先迁移/归档到 `docs/history/` 或 CI 工件，不再在本清单中逐一登记。

## 顶层子目录

| Path           | Type       | Audience            | Scope                                                                                           | Status        |
|----------------|------------|---------------------|--------------------------------------------------------------------------------------------------|---------------|
| `.claude/`     | tooling    | developer, AI       | Claude/openspec 集成命令与计划文件，仅服务于本地 AI 辅助开发，不影响部署产物。                 | supporting    |
| `.cursor/`     | tooling    | developer, AI       | Cursor 编辑器的命令与计划配置，用于提升本地开发效率。                                           | supporting    |
| `.spec-workflow/` | tooling | developer           | OpenSpec 工作流辅助工具与模板（approvals/config/templates 等），不影响运行时行为。             | supporting    |
| `.specify/`    | tooling    | developer, AI       | Specify/plan 工具的记忆与脚本模板，用于管理 AI 辅助开发计划与上下文。                          | supporting    |
| `docs/`        | docs       | developer, reviewer | 长期维护的架构/测试/运维规范与历史案例索引；具体文档由 `docs/FILE_INVENTORY.md` 管理。        | authoritative |
| `scripts/`     | scripts    | developer, operator | 面向用户/CI 的脚本入口集合，统一暴露 clean/bootstrap/reconcile 等能力；详见 `scripts/README.md`。 | authoritative |
| `tests/`       | tests      | developer, reviewer | 回归与冒烟测试脚本、bats 用例与辅助测试工具；执行策略由 `README_TESTING.md` 与 docs/testing 文档约束。 | primary       |
| `webui/`       | module     | developer, user     | Kindler WebUI（前端/后端/测试）源码与构建配置；文档由 `webui/FILE_INVENTORY.md` 管理。        | authoritative |
| `tools/`       | tools      | developer, operator | 运维/诊断/维护工具集合，非直接入口；子树由 `tools/FILE_INVENTORY.md` 管理。                   | primary       |
| `examples/`    | examples   | developer           | Kindler 配置与工作流的最小示例；子树由 `examples/FILE_INVENTORY.md` 管理。                    | primary       |
| `openspec/`    | spec       | developer, reviewer | OpenSpec 规格与变更提案目录，定义项目级 Requirements 与变更任务清单。                         | primary       |
| `argocd/`      | manifests  | developer, operator | ArgoCD ApplicationSet 等声明式清单，与 devops 集群集成；不直接部署业务应用。                  | primary       |
| `clusters/`    | config     | developer, operator | k3d/kind 集群模板与默认配置（YAML），供脚本与 WebUI 引用。                                     | primary       |
| `compose/`     | infra      | developer, operator | Docker Compose 与 HAProxy/Portainer 等基础设施编排文件。                                       | primary       |
| `config/`      | config     | developer, operator | 运行时配置与 `.env` 模板（不含真实机密），供脚本/WebUI 读取。                                  | primary       |
| `deploy/`      | infra      | developer, operator | Kindler 自身部署的 Helm chart 与 values。                                                       | primary       |
| `infrastructure/` | infra   | developer, operator | 基础设施相关配置与脚本（如宿主机准备、网络等），不直接暴露给终端用户。                        | supporting    |
| `logs/`        | logs       | developer, operator | 长期保留的结构化审计日志与必要调试日志位置，具体文件按 `.gitignore` 与 CI 约定管理。          | supporting    |
| `data/`        | data       | developer, operator | 数据目录与 SQLite/测试数据挂载点，仅存放运行时数据或示例，不直接放置文档。                    | supporting    |
| `manifests/`   | manifests  | developer, operator | Kubernetes YAML 清单（按需使用），由架构/测试文档引用。                                        | supporting    |
| `worktrees/`   | dev-env    | developer           | 本地 Git worktree 根目录，未纳入版本控制；仅用作开发分支工作区，占位说明其用途。             | supporting    |
