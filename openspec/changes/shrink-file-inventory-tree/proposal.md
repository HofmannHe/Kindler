## Why
- 在 `reduce-report-noise` 与 `enforce-file-inventory-tree` 之后，仓库已经有了 `FILE_INVENTORY_ALL.md` + 各目录 `FILE_INVENTORY.md` + 审计脚本（`scripts/file_inventory.sh` / `scripts/file_inventory_tree.sh` / `scripts/file_tree_audit.sh`），但大量历史报告、一次性测试脚本和重叠文档仍然存在，特别是 `docs/history/`、`tests/`、`docs/` 与仓库根目录。
- `scripts/file_tree_audit.sh` 的 WARNING 表明多个目录远超推荐的单目录文件数量上限（例如 15 个文件），新贡献者很难在这些目录中快速识别“唯一可信文档”和“唯一测试入口”，也难以判断哪些文件仍然被规格/回归依赖。
- 目前的 FILE_INVENTORY 清单树回答了“每个文件负责什么”，但没有明确驱动“哪些文件应该被删除、归档或合并”，导致历史产物被动地长期留在仓库中，增加维护成本和认知负担。
- 你希望引入一个基于 FILE_INVENTORY 的“文件收缩与归并”阶段：分批对大目录做结构化清理，在不破坏现有 clean/bootstrap/reconcile/smoke/regression 验收链路的前提下，删除/归档不再必要的文件、合并语义重叠文档/脚本，并把零散功能收拢到职责清晰的模块中。

## What Changes
1. 在 tooling-scripts 规格中新增“文件收缩与归并”相关 Requirements：
   - 定义一个基于 FILE_INVENTORY 清单树的收缩流程：对被 `scripts/file_tree_audit.sh` 标记为超限的目录，逐一为其中的文件做“保留/合并/归档/删除”决策，并同步更新对应的 FILE_INVENTORY 条目。
   - 要求对被保留的长期文件明确唯一职责和所属模块；对被合并的内容要求在 canonical 文档/脚本中记录来源，并清理旧引用；对被归档的历史案例要求迁移到受控的 `docs/history/`（或等价目录）并在清单中做 `legacy` 标识。
   - 将 `scripts/file_tree_audit.sh`、`scripts/file_inventory_tree.sh` 与 `scripts/scripts_inventory.sh` 视为“文件收缩的护栏”，要求在每次收缩批次完成后通过这些检查，确保既没有幽灵文件，也没有失控增长的目录。
2. 为 Key 目录制定分批收缩策略：
   - 第一批聚焦 `docs/history/`：把大量一次性报告/阶段总结整理为有限数量的“案例级”历史文档（按主题/时间归并），其余文件要么删除、要么折叠进 `docs/` 中的规范性文档（例如 REGRESSION/TESTING/WEBUI 相关指南）。
   - 第二批聚焦 `docs/` 和仓库根目录：对规范性文档做去重与合并（例如成对的 TESTING_GUIDE/TESTING_GUIDELINES），同时清理根目录下的日志类文件与过时说明，保证 `FILE_INVENTORY.md` 中的顶层角色描述清晰、无重叠。
   - 第三批聚焦 `tests/` 与脚本入口：按“回归/冒烟/一致性/WebUI/实验/废弃”重组测试脚本；保留少量 canonical 入口（如 `scripts/regression.sh` / `scripts/smoke.sh` / `tests/regression_test.sh`），并为其他脚本定义明确的迁移路径（包装到 lib 或 tools），最终删除不再需要的重叠入口。
3. 在 Spec 中约束“防止回弹”的行为：
   - 新增约束：新增文档/脚本/测试时，必须先确认是否可以扩展现有 canonical 文件，而不是新增一个语义高度重叠的并列文件；FILE_INVENTORY 清单以及 `scripts/scripts_inventory.sh` 的输出需要反映这一决策。
   - 要求在每次大规模收缩后，通过 `scripts/file_tree_audit.sh --max-per-dir N` 输出对比前后的目录规模变化，并在 `IMPLEMENTATION_SUMMARY.md` 或等价位置记录“本轮收缩覆盖的目录和决策策略”，作为后续 PR/变更的审查依据。

## Impact
- tooling-scripts 规格将新增一组约束，要求把现有的 FILE_INVENTORY 清单树从“只做说明”提升为“主动驱动文件收缩的决策工具”，避免 `docs/history/`、`tests/` 等目录继续无上限累积文件。
- 实现阶段会导致仓库中大量历史报告与冗余测试脚本被删除或迁移；短期内 diff 较大，但通过 FILE_INVENTORY 与回归脚本的双重护栏，可以在不破坏现有 clean/bootstrap/reconcile/smoke/regression 验收链路的前提下完成收缩。
- 对新贡献者而言，`docs/` 将聚焦少量核心规范文档，`docs/history/` 仅保留小规模“案例库”，`tests/` 与 `scripts/` 会呈现更清晰的入口与职责分层，有助于缩短理解成本并降低未来变更时的意外破坏风险。
- 该变更不会引入新的运行时依赖或网络调用，仅依赖现有的 Bash 脚本和 SQLite/Git 元数据；一旦收缩策略效果不佳，可以在 Git 层面回滚或通过后续变更进一步调整。

