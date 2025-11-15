# FILE_PLAN（仓库根目录）

> 本文件继承 `docs/FILE_INVENTORY.md` 的约束，聚焦“仓库根目录的目录级规划”，只描述当前目录下的顶层文件与子目录的职责边界；更深层结构由各自目录下的 FILE_INVENTORY/README 继续细化。

## 顶层目录白名单

| Path          | Purpose                                                     | Owner                 | Allowed Types/Subdirs                                       | Forbidden Items                         |
|---------------|-------------------------------------------------------------|-----------------------|--------------------------------------------------------------|-----------------------------------------|
| `argocd/`     | 存放 ArgoCD ApplicationSet 等声明式清单，与 devops 集群集成。 | DevOps owner          | 应用清单 YAML、README                                       | 运行日志、一次性调试脚本                |
| `clusters/`   | 记录集群模板与默认配置（k3d/kind），供脚本与 WebUI 引用。   | Infra owner           | YAML、示例配置、README                                     | 实际 kubeconfig、敏感凭据              |
| `compose/`    | Docker Compose 与 HAProxy/Portainer 等基础设施编排文件。    | Infra owner           | Compose 文件、HAProxy 配置、SSL 证书占位/示例              | 真实私钥（仅允许本地未提交的机密文件）  |
| `config/`     | 集群/项目/GitOps 等运行时配置与 `.env` 模板。               | Infra owner           | `*.env.example`、CSV、README                               | 真实密码/Token（通过 .gitignore 管理）  |
| `deploy/`     | 用于 Kindler 自身部署的 Helm chart 与 values。              | Infra owner           | Chart/values YAML、README                                  | 运行时生成的 release 记录              |
| `docs/`       | 长期维护的架构/测试/运维规范与历史案例索引。                 | Project owner         | 规范文档、测试计划、历史案例索引、FILE_INVENTORY           | 新增一次性报告（应优先放入 docs/history） |
| `examples/`   | Kindler 配置与工作流的最小示例。                           | Project owner         | 示例 README、示例配置文件                                  | 实际生产配置、敏感信息                  |
| `openspec/`   | OpenSpec 项目规格与变更提案目录。                           | Spec owner            | `project.md`、specs/、changes/                             | 运行日志、测试产物                      |
| `scripts/`    | 面向用户/CI 的脚本入口集合，统一暴露 clean/bootstrap 等能力。 | Infra owner           | 可执行脚本、lib/ 辅助函数、README、测试 fixture           | 临时调试脚本（建议放在 worktrees 分支） |
| `tests/`      | 回归与冒烟测试脚本、bats 用例等。                           | QA / Infra owner      | 测试脚本、fixtures、README                                 | 测试运行生成的日志/报告（应在 logs/ 或 CI 工件中） |
| `tools/`      | 非直接入口的维护/诊断工具集合，由高级用户/管理员调用。      | Infra owner           | 运维脚本、子目录级 FILE_INVENTORY、README                  | 长期无人维护的“实验性脚本堆积”          |
| `webui/`      | Kindler WebUI（前端/后端/测试）的源码与构建配置。           | WebUI owner           | 前后端代码、测试、README、webui/FILE_INVENTORY             | 运行日志、一次性调试输出                |
| `logs/`       | 长期保留的结构化审计日志与必要的调试日志位置。              | Infra owner           | JSONL、按需生成的 `.log`（应通过 .gitignore 管理是否版本化） | 新增长期持久化的 Markdown 报告          |

## 根目录单文件（补充说明）

> 根目录下的 README、AGENTS 等核心文档的详细用途与边界由 `docs/FILE_INVENTORY.md` 描述，此处不再重复；新增长期存在的根目录文件时，应同时更新 `docs/FILE_INVENTORY.md` 与 `FILE_INVENTORY_ALL.md`。

