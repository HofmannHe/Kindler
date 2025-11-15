## Why
- 目前仓库已经通过 `docs/FILE_INVENTORY.md`、`examples/FILE_INVENTORY.md` 与 `FILE_INVENTORY_ALL.md` 建立了“文档清单 + 全局严格白名单”的基础，但缺少一棵自顶向下的“文件清单树”，很难从结构上回答“某个目录/文件究竟负责什么、不负责什么”。
- 文档与脚本不断演进，历史报告与一次性产物逐渐堆积，如果没有层次化的清单与边界，后续清理很难做到“删除某个目录不会破坏核心能力”。
- 你希望在不破坏现有回归脚本与 GitOps 约束的前提下，引入一套可递归检查的 FILE_INVENTORY/FILE_PLAN 体系：从根目录开始，每一级目录都有局部清单说明“包含哪些子目录/关键文件、用途是什么、由谁负责”，整体形成一棵覆盖所有 Git 跟踪文件的树。
- 你还希望在此基础上引入“目录文件数量上限（例如 ≤15）”的约束，用脚本先给出审计结果与优化建议，再分批重构目录结构，避免一次性大改难以回滚。

## What Changes
1. 在 tooling-scripts 规格中新增“层次化文件清单树”相关 Requirements：
   - 定义从仓库根目录开始的 FILE_INVENTORY / FILE_PLAN 约定，每个清单只负责当前目录下的文件和直接子目录，整体形成一棵树。
   - 要求每个局部清单至少为“长期存在”的文件/子目录提供简短的 Purpose/Owner/Scope 描述，保持不同文档和目录职责正交。
   - 保留 `FILE_INVENTORY_ALL.md` 作为“全局严格白名单”，但通过脚本确保其中所有路径都可以被某个局部清单节点解释（直接或通过上层目录条目）。
2. 引入轻量的目录规模审计机制（Phase 1）：
   - 基于 `git ls-files` 统计每个目录（按相对路径）下的文件数量，生成“目录规模报告”，标记超过推荐上限（如 15 个文件）的目录。
   - 在本阶段仅以 WARNING 形式输出，不强制失败；后续批量清理完成后再允许通过严格模式将其变为 MUST。
3. 为关键子树补充局部 FILE_INVENTORY：
   - 在 `webui/`、`tools/` 等目录下引入本地 `FILE_INVENTORY.md`，描述子目录/关键文件的用途与边界，补足当前仅有 docs/examples 的清单空缺。
   - 必要时在仓库根目录新增 `FILE_PLAN.md` 或等价清单，解释顶层目录（scripts/tools/webui/openspec 等）的角色与所有权，对应样例中的“子目录白名单”。
4. 更新脚本入口与统一检查流程：
   - 扩展 `scripts/scripts_inventory.sh --check`，在保持现有行为的前提下增加：
     - 调用新的“文件清单树检查”脚本（例如 `scripts/file_tree_audit.sh`）用于目录规模审计；
     - 调用 `webui/FILE_INVENTORY`、`tools/FILE_INVENTORY` 等新增局部清单检查脚本。
   - 确保新的检查默认轻量、可选，既不引入网络/集群依赖，也不会改变 clean/bootstrap/reconcile 回归链路。

## Impact
- tooling-scripts 规格将多出一组与 FILE_INVENTORY/FILE_PLAN 相关的 Requirements，明确“自顶向下的文件清单树 + 全局严格白名单”的组合策略，后续所有新文件/新目录都必须在相应清单中登记。
- 新增的审计脚本会帮助发现“单个目录文件过多”的情况，并给出重构信号，但在本阶段不会阻断回归或 CI；目录实际拆分、文件迁移会在后续变更中分批进行。
- `webui/`、`tools/` 等目前缺乏集中说明的子树会获得局部 FILE_INVENTORY，方便在评审时快速理解“某个文件/目录仍然是否必要、用途是否与其他文件重叠”，为后续删除/迁移提供依据。
- 所有改动将保持现有 clean/bootstrap/reconcile/smoke/regression 脚本行为不变，仅通过额外检查脚本和清单文件增加“可观测性与治理”，可以随时回滚到变更前状态。

