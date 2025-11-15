## ADDED Requirements

### Requirement: 基于 FILE_INVENTORY 的文件收缩与归并
仓库 SHALL 使用 FILE_INVENTORY 清单树作为删除/归档/合并文件的决策基础，在收缩文件数量的同时保持责任边界清晰且回归链路可用。

#### Scenario: 使用 FILE_INVENTORY 驱动收缩决策
- **GIVEN** 仓库已经维护 `FILE_INVENTORY_ALL.md` 以及根目录/子目录的 `FILE_INVENTORY.md`，且 `scripts/file_inventory_tree.sh --check` 通过
- **WHEN** 维护者计划对某个目录执行“文件收缩与归并”（例如对历史报告、测试脚本或说明文档做批量清理）
- **THEN** 他们 SHALL 先基于对应目录的 FILE_INVENTORY 条目，为每个长期文件给出“保留/合并/归档/删除”的明确决策
- AND 对于被保留的文件，清单中 MUST 说明其 Purpose/Owner/Scope 并指向所属模块（如 `docs/REGRESSION_TEST_PLAN.md`、`tests/regression_test.sh`、`scripts/regression.sh` 等）
- AND 对于被合并或归档的文件，清单中 MUST 更新到新的 canonical 位置或历史案例位置（例如标记为 `history`/`legacy` 并指向 `docs/history/` 中的条目），并删除对旧路径的引用
- AND 收缩决策 SHALL 仅在各层级 `FILE_INVENTORY.md` 清单中表达（通过 Purpose/Scope/Status=legacy 等字段），而不在 `FILE_INVENTORY_ALL.md` 中直接编码语义
- AND `FILE_INVENTORY_ALL.md` SHALL 仅作为基于 `git ls-files` 生成的全局严格白名单，由 `scripts/file_inventory_all.sh` 等脚本机械维护，用于发现“幽灵文件”或清单遗漏
- AND 完成该批次收缩后，`scripts/file_inventory.sh --check`、`scripts/file_inventory_tree.sh --check` 和 `scripts/file_inventory_all.sh --check` 均通过，表明没有遗漏更新清单

#### Scenario: 收缩后通过目录审计与回归链路
- **WHEN** 某个目录完成一次收缩批次后运行 `scripts/file_tree_audit.sh --max-per-dir N`
- **THEN** 该目录的文件数量 SHOULD 接近或低于约定阈值 N（例如 15），并在审计输出中明显优于收缩前
- AND 项目仍然能够在不修改验收脚本的前提下，通过 `scripts/regression.sh --full` 与 `scripts/smoke.sh <env>` 所要求的 clean → bootstrap → reconcile → smoke/tests 链路
- AND 若收缩导致回归失败，维护者 MUST 更新本 Requirement 对应变更的 `tasks.md` 与具体实现，直到在保持文件收缩效果的同时恢复所有必需的测试通过

### Requirement: 历史报告与规范文档的边界收紧
历史/报告类文档 SHALL 被限制在受控的历史目录与少量规范性文档中，避免无限制扩张并与核心文档职责重叠。

#### Scenario: docs/history 收缩为有限案例库
- **WHEN** 贡献者查看 `docs/history/` 目录并结合 `docs/FILE_INVENTORY.md`
- **THEN** 该目录仅包含数量有限、在清单中标记为 `history`/`legacy` 的案例级文档（例如关键回归、架构决策、重大事故回顾）
- AND 大量一次性测试报告、阶段性总结、自动生成的 `FINAL_*` / `*_REPORT.md` 文件 SHALL 已被删除或其内容被合并进核心规范文档
- AND 新增的测试/回归运行默认只通过 stdout/CI 报告结果，而不会再向 `docs/history/` 添加新的 Markdown 报告文件，除非在 specs 中显式注明为长期保留案例

#### Scenario: docs/ 聚焦少量 canonical 规范文档
- **WHEN** 贡献者打开 `docs/` 并对照 `docs/FILE_INVENTORY.md`
- **THEN** 可以明显分辨少量 canonical 文档（例如 ARCHITECTURE、REGRESSION_TEST_PLAN、TESTING_GUIDE、scripts_inventory 等），且不存在成对或多份语义高度重叠的文档（如测试指南的多份复制版）
- AND 如果某个主题存在多个旧版本说明（例如 `TESTING_GUIDE.md` 与 `TESTING_GUIDELINES.md`），内容 SHALL 被合并到单一 canonical 文档中，旧文件删除或标记为历史并迁移到 `docs/history/`
- AND `scripts/file_tree_audit.sh` 对 `docs/` 与 `docs/history/` 的 WARNING 数量随本变更的实施而显著降低

### Requirement: 测试与脚本入口的收敛
测试脚本与运维脚本的入口集合 SHALL 保持精简且职责清晰，避免存在大量功能重叠的并列入口。

#### Scenario: 测试入口按类别收敛
- **WHEN** 贡献者列出 `tests/` 目录并查阅 FILE_INVENTORY 中对测试脚本的说明
- **THEN** 可以看到测试脚本按“回归/冒烟/一致性/WebUI/实验或废弃”等类别清晰分组
- AND 对于常用路径仅保留少量 canonical 入口（例如 `tests/regression_test.sh`、`tests/webui_e2e_test.sh`），其他脚本要么作为这些入口内部调用的库，要么在清单中标记为 `legacy` 并计划在后续变更中删除
- AND `scripts/scripts_inventory.sh --markdown` 生成的 `docs/scripts_inventory.md` 中，测试/运维相关脚本的类别与状态能够反映这种收敛结果（例如标记废弃脚本、突出推荐入口）

#### Scenario: 运维脚本与测试脚本职责分离
- **WHEN** 贡献者查阅 `scripts/` 目录和 `tools/` 目录的 FILE_INVENTORY 说明
- **THEN** `scripts/` 仅包含生命周期与 GitOps 相关的 canonical 入口（如 clean/bootstrap/reconcile/smoke/regression 等），而不再包含大量一次性的调试或修复脚本
- AND 需要长期保留的调试/修复脚本被移动到 `tools/` 并在 FILE_INVENTORY 中注明用途，废弃脚本在本变更或后续批次中删除
- AND 对新的辅助脚本，评审者 SHALL 首先考虑将其实现为 `tools/` 下的子命令或现有脚本的子功能，而不是在 `scripts/`/`tests/` 下增加新的顶层入口
