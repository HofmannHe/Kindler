# FILE_INVENTORY（文档文件清单）

> 本清单用于管理本仓库中“长期存在”的文档文件，明确每个文件的用途、目标读者与责任边界，避免出现大量职责重叠、难以维护的过程文档。

## 使用约定

- 本清单列出**核心文档**以及已标记为 `legacy` 的历史/过程文档，用于实现“严格白名单”管理；未在此列出且不在历史/归档目录的 Markdown 文件视为异常。
- 一次性测试报告、阶段性总结等过程性文档，原则上应迁移到 `docs/history/` 或由 PR/CI 描述承载；在迁移完成前，可在本清单中以 `Status=legacy` 暂时保留。
- 新增核心文档时，必须在本文件中补充条目；新增一次性报告应放入 `docs/history/` 或对应归档目录，通常不需要登记为核心文档。
- `scripts/file_inventory.sh --check` 将根据本清单校验根目录和 `docs/` 下的 Markdown 文件是否登记；未登记且不在历史/归档目录的 Markdown 文件会被视为异常。

## 字段说明

- `Path`：文件相对于仓库根目录的路径。
- `Type`：文档类型，例如：`architecture` / `testing-plan` / `testing-guide` / `operations` / `spec` / `webui` / `project-management` / `history-index` 等。
- `Audience`：目标读者，例如：`developer` / `operator` / `user` / `reviewer`。
- `Scope`：责任边界，说明该文档“负责什么、不负责什么”，尽量一句话说清楚。
- `Status`：当前状态，建议值：`authoritative`（唯一权威）、`primary`（主要参考）、`legacy`（保留待清理）。

## 根目录核心文档

| Path                               | Type          | Audience            | Scope                                                                                          | Status        |
|------------------------------------|---------------|---------------------|-------------------------------------------------------------------------------------------------|---------------|
| `README.md`                        | overview      | developer, user     | 项目总体介绍与快速上手入口，不展开架构/测试细节。                                             | authoritative |
| `README_CN.md`                     | overview      | developer, user     | README 中文版，保持与 `README.md` 内容同步。                                                   | authoritative |
| `README_EN.md`                     | overview      | developer, user     | README 英文版，保持与 `README.md` 内容在语义上同步，供英文读者参考。                           | authoritative |
| `ARCHITECTURE.md`                  | architecture  | developer, reviewer | 顶层架构总览，描述核心组件关系与数据流，不替代详细设计文档。                                 | primary       |
| `AGENTS.md`                        | process       | developer, AI       | 面向 Agent/贡献者的操作约束与开发模式说明，不重复 README 内容。                               | authoritative |
| `README_TESTING.md`                | testing-guide | developer, reviewer | 测试总览与入口说明，引用而不重复详细测试计划。                                                 | primary       |
| `README_RECONCILER.md`             | operations    | developer, operator | Reconciler 行为与使用说明，不覆盖整体架构。                                                   | primary       |
| `CHANGELOG.md`                     | changelog     | developer, reviewer | 记录基础设施与脚本的主要变更历史，帮助理解版本间差异，不替代详细设计与规范文档。             | primary       |
| `CHANGELOG_WEBUI.md`               | changelog     | developer, reviewer | 记录 WebUI 相关变更历史，聚焦前端/后端与集成层面的变更。                                     | primary       |
| `FILE_INVENTORY_ALL.md`            | inventory     | developer, reviewer | 全局文件清单（所有 Git 跟踪文件的严格白名单），用于驱动 scripts/file_inventory_all.sh 审计与清理。 | authoritative |
| `FILE_PLAN.md`                     | structure-plan| developer, reviewer | 根目录目录级规划，描述顶层子目录的 Purpose/Owner/Scope，作为“文件清单树”的入口说明。        | primary       |

## 顶层子目录文档（一级）

| Path                     | Type               | Audience        | Scope                                                                                 | Status  |
|--------------------------|--------------------|-----------------|----------------------------------------------------------------------------------------|---------|
| `scripts/README.md`      | scripts-guide      | developer       | 脚本目录总览与约定说明，描述主要入口脚本、元数据约束及与 docs/scripts_inventory.md 的关系。 | primary |
| `webui/README.md`        | webui-dev-guide    | developer       | WebUI 目录结构与本地开发说明，覆盖 backend/frontend/tests 的开发与测试流程。          | primary |
| `webui/README_POSTGRESQL.md` | webui-db-legacy | developer       | WebUI PostgreSQL 集成的早期文档，描述 Postgres 为主、SQLite 为备的模式，仅作历史参考。 | legacy  |
| `webui/FILE_INVENTORY.md` | inventory         | developer, reviewer | WebUI 子树的局部文件清单，说明 webui/ 下 README 与核心子目录的职责与边界。              | primary |
| `tools/FILE_INVENTORY.md` | inventory         | developer, reviewer | tools 子树的局部文件清单，从目录层面说明工具脚本集合与核心子目录的用途与边界。          | primary |

## docs/ 目录核心文档

| Path                                        | Type                   | Audience            | Scope                                                                                       | Status        |
|---------------------------------------------|------------------------|---------------------|----------------------------------------------------------------------------------------------|---------------|
| `docs/ARCHITECTURE.md`                      | architecture           | developer, reviewer | 与根目录 `ARCHITECTURE.md` 配合，提供更细粒度的架构说明。                                   | primary       |
| `docs/KINDLER_CONFIG_SPEC.md`               | spec                   | developer, operator | Kindler 配置模型与字段说明，作为配置相关的唯一规范来源。                                   | authoritative |
| `docs/GITOPS_WORKFLOW.md`                   | operations             | developer, operator | GitOps 工作流与分支策略说明，不重复 openspec 细节。                                        | primary       |
| `docs/REGRESSION_TEST_PLAN.md`              | testing-plan           | developer, reviewer | 回归测试计划的唯一规范文档，描述完整回归步骤与判定标准。                                   | authoritative |
| `docs/TESTING_GUIDE.md`                     | testing-guide          | developer           | 日常测试指南与示例，整合历史 TESTING_GUIDELINES 内容，并引用 `REGRESSION_TEST_PLAN` 和脚本入口。 | authoritative |
| `docs/scripts_inventory.md`                 | scripts-inventory      | developer, reviewer | 脚本清单与状态审计，必须与 `scripts/*.sh` 实际入口保持同步。                                | authoritative |
| `docs/WEBUI.md`                             | webui                  | developer, user     | WebUI 功能与使用入口，不覆盖 WebUI 深度问题分析文档。                                      | primary       |
| `docs/WEBUI_FIX_SUMMARY.md`                 | webui-history          | developer, reviewer | WebUI 修复与演进的集中总结文档，汇总主要问题与修复决策，作为 WebUI 历史案例的入口索引。     | primary       |
| `docs/IMPLEMENTATION_SUMMARY.md`            | implementation-summary | developer, reviewer | 实施与自动化相关变更的整体总结与统一入口，整合历史 IMPLEMENTATION_* 文档中的关键结论。      | primary       |
| `docs/CLUSTER_MANAGEMENT.md`                | operations             | developer, operator | 集群管理策略与日常操作指南，描述 devops/业务集群的管理职责与边界。                         | primary       |
| `docs/GITOPS_ARCHITECTURE.md`               | architecture           | developer, reviewer | GitOps 架构与分支策略的完整说明，补充 `docs/GITOPS_WORKFLOW.md` 的高层流程描述。           | primary       |
| `docs/ROUTING_GUIDELINES.md`                | operations             | developer, operator | HAProxy 路由与入口规范，防止管理域名被错误路由到 devops 集群，作为路由配置的约束文档。     | primary       |
| `docs/CLUSTER_LIFECYCLE_VALIDATION_GUIDE.md` | testing-guide         | developer, reviewer | 集群生命周期验证指南，描述从创建到删除的验证步骤与注意事项。                               | primary       |
| `docs/PROJECT_MANAGEMENT.md`                | project-management     | developer, reviewer | 项目管理与阶段拆解文档，描述从需求到回归的整体迭代流程。                                   | primary       |
| `docs/ARGOCD_SETUP.md`                      | operations             | developer, operator | ArgoCD 安装与配置步骤的集中说明，用于理解/排查 GitOps 管理集群部署。                       | primary       |

## 历史与归档文档

- 历史案例文档统一放在 `docs/history/` 或未来的 `docs/archive/` 目录下；这些文件记录某次重要事件/故障/迁移的全过程。
- 本清单中仅以“索引”的形式列出 **少量关键案例**，其余历史文档已在本次收缩中删除或折叠进 canonical 文档（如 REGRESSION/TESTING/WEBUI/IMPLEMENTATION 相关指南）；如需完整细节可通过 Git 历史查看。

| Path                                                | Type         | Audience            | Scope                                                                                 | Status  |
|-----------------------------------------------------|--------------|---------------------|----------------------------------------------------------------------------------------|---------|
| `docs/history/CRITICAL_INFRASTRUCTURE_ISSUES.md`    | history-case | developer, reviewer | 关键基础设施问题的集中记录与分析，作为后续架构/测试决策的核心历史案例之一。         | legacy  |
| `docs/history/COMPLETE_FAILURE_ANALYSIS.md`         | history-case | developer, reviewer | 某轮完整失败与修复过程的详细分析报告，用于理解系统在极端情况下的行为与改进方向。   | legacy  |
| `docs/history/REGRESSION_TEST_REPORT_20251024.md`   | history-case | developer, reviewer | 2025-10-24 完整回归测试的代表性报告，保留作为回归流程/脚本协同的典型案例。         | legacy  |
| `docs/history/IMPLEMENTATION_COMPLETE_SUMMARY.md`   | history-case | developer, reviewer | 某次完整实施收尾与一致性完善的过程记录，作为实现阶段收敛与自动化治理的代表性案例。 | legacy  |
| `docs/history/HONEST_STATUS_REPORT_20251020.md`     | history-case | developer, reviewer | 围绕实现/回归状态的诚实汇报与剩余风险说明，用于展示“真实状态报告”的实践样例。     | legacy  |
| `docs/history/WEBUI_REAL_SCRIPTS_INTEGRATION_FINAL_REPORT.md` | history-case | developer, reviewer | WebUI 与真实脚本集成的最终总结报告，用于理解 WebUI 与脚本系统集成的关键演进。 | legacy  |
| `docs/history/WEB_UI_INTEGRATION_STATUS_FINAL.md`   | history-case | developer, reviewer | WebUI 集成状态与问题的最终总结，仅作历史参考，与上游架构/实现文档配合使用。        | legacy  |

> 说明：今后新增历史案例时，应优先复用上述代表性文档或通过 PR/CI 工件记录，而不是在 `docs/history/` 中继续累积平行的 `*_SUMMARY.md` / `*_REPORT.md` 文件。

## 清理与迁移原则

- 新的核心文档：
  - 必须在本清单中新增条目，说明类型、目标读者与责任边界；
  - 应避免与现有文档职责重叠，若涉及已有主题，应优先扩展已有文档而不是新建一个平行文档。
- 过程性/一次性文档：
  - 优先通过 PR 描述或 CI 报告承载；
  - 如确有必要落盘，应放入 `docs/history/`，并在清单中将其标记为 `history-case` / `legacy`。
- 废弃文档：
  - 当某文档完全被新的“单一事实来源”取代时，应在本清单中标为 `legacy` 并计划删除；
  - 删除前可在新文档中保留简短迁移说明，方便从旧链接过来的读者找到新入口。
