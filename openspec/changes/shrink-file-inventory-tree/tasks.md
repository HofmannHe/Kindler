1. - [ ] 梳理目录规模与 FILE_INVENTORY 覆盖现状
   - 运行 `scripts/file_tree_audit.sh --max-per-dir 15`，记录当前 WARNING 中的主要目录（预计包括 `docs/history/`、`tests/`、`scripts/`、`docs/` 与仓库根目录 `.`），为后续收缩提供基线数据。
   - 运行 `scripts/file_inventory.sh --check`、`scripts/file_inventory_tree.sh --check` 与 `scripts/file_inventory_all.sh --check`，确认现有 FILE_INVENTORY 清单树与全局白名单一致，收集尚未被清单覆盖的异常路径（如有）。
   - 在本 change 目录补充一份简短的 `inventory.md` 或在 `proposal.md` 末尾追加附录，按目录总结：哪些文件属于长期规范文档、哪些是历史/报告类、哪些是一次性测试脚本或调试脚本。

2. - [ ] 设计 docs/history 与 docs/ 的收缩策略（Phase 3A/3B 规划）
   - 阅读 `docs/FILE_INVENTORY.md` 与 `docs/history/` 下的各类报告文件，按主题/时间/用途将文档分组（例如：回归测试报告、WebUI 修复历史、架构演进记录等）。
   - 为每一类文档决定策略：选择 1–2 个代表性案例作为长期历史文档保留，其余内容合并到 canonical 规范文档（如 `REGRESSION_TEST_PLAN.md`、`TESTING_GUIDE.md`、`WEBUI.md`）或删除。
   - 识别 `docs/` 下语义重叠的文档（例如 `TESTING_GUIDE.md` vs `TESTING_GUIDELINES.md`、多份 WEBUI/配置说明），设计“合并到单一 canonical 文档 + 迁移引用”的方案。
   - 在 `docs/FILE_INVENTORY.md` 中为 `docs/history/` 及各核心文档补充/调整 Purpose/Owner/Scope，明确哪些是规范性文档、哪些是 `history`/`legacy` 案例。

3. - [ ] 执行 docs/history 第一批清理（Phase 3A 实施）
   - 根据前一步的分组与策略，对 `docs/history/` 中明显一次性的测试报告与阶段性总结执行删除或合并：保留少量案例级文档，其余内容折叠进 canonical 文档或直接删除。
   - 确认不存在仍被 README/REGRESSION/TESTING 等规范性文档显式引用却被删除的文件；必要时先更新引用再删除原文件。
   - 更新 `docs/FILE_INVENTORY.md` 与根目录 `FILE_INVENTORY.md`，确保所有保留的历史文档都有明确的用途说明，并对计划在后续变更中删除的 `legacy` 文档做标记。
   - 运行 `scripts/file_inventory.sh --check`、`scripts/file_inventory_tree.sh --check` 与 `scripts/file_tree_audit.sh --max-per-dir 15`，确认清单树与目录规模审计仍然通过，且 `docs/history/` 的 WARNING 有所收敛。

4. - [ ] 收敛 docs/ 与根目录文档/日志（Phase 3B 实施）
   - 按规划合并 `docs/` 中语义重叠的文档：选择单一 canonical 文件作为“唯一事实来源”，将其他文档的有效内容迁移进来，并在必要时添加简短迁移说明。
   - 清理仓库根目录下不再需要的日志文件与过时说明（例如历史 `*_REPORT.md`、`full_regression_*.log` 这类已被 reduce-report-noise 视为构建产物的文件），确保 `.gitignore` 覆盖新产生的日志。
   - 更新根目录 `FILE_INVENTORY.md` 与 `docs/FILE_INVENTORY.md`，使顶层目录与核心文档的角色描述保持正交；必要时给出“从根目录到文档”的推荐阅读路径。
   - 再次运行 `scripts/file_inventory.sh --check`、`scripts/file_inventory_tree.sh --check`、`scripts/file_inventory_all.sh --check` 与 `scripts/file_tree_audit.sh --max-per-dir 15`，验证收缩后的清单树与目录规模都符合预期。

5. - [ ] 收敛 tests/ 与脚本入口（Phase 3C 规划与实施）
   - 对 `tests/` 下的脚本按用途分组：回归/冒烟/一致性/WebUI/验收/实验或废弃等，标记出已经被 `scripts/regression.sh`、`scripts/smoke.sh`、`tests/regression_test.sh` 等 canonical 入口覆盖的重叠脚本。
   - 为每个分组设计迁移策略：常用路径保留少量 canonical 入口，其余脚本转为被调用的库（例如抽取到 `tests/lib.sh` 或 `scripts/lib/*`），或在 FILE_INVENTORY 中标注为 `legacy`，准备在后续变更中删除。
   - 检查 `scripts/` 与 `tools/` 目录：确保生命周期与 GitOps 相关入口集中在 `scripts/`，调试/修复类脚本集中在 `tools/`；为明显一次性的调试脚本设计删除或迁移计划。
   - 更新相关 FILE_INVENTORY（根目录、`docs/`、`tests/`、`scripts/`、`tools/`），确保测试入口与脚本入口的职责分层在清单中可见，并通过 `scripts/scripts_inventory.sh --check` 验证。

6. - [ ] 运行 openspec 验证与回归自检
   - 在规格调整与第一轮收缩任务完成后，运行 `openspec validate shrink-file-inventory-tree --strict`，确保本变更的 proposal/tasks/spec delta 结构正确、引用一致。
   - 按项目 AGENTS 与 tooling-scripts 规格要求，至少完成一轮完整回归：`scripts/clean.sh --all` → `scripts/bootstrap.sh` → 利用 SQLite 中的集群描述运行 `scripts/reconcile_loop.sh --once --prune-missing` → 使用 `scripts/create_env.sh` 创建 ≥3 kind / ≥3 k3d 环境 → 对所有非 devops 环境运行 `scripts/smoke.sh <env>`。
   - 在上述回归流程中，确保 `scripts/file_inventory.sh --check`、`scripts/file_inventory_tree.sh --check`、`scripts/file_inventory_all.sh --check` 与 `scripts/scripts_inventory.sh --check` 均通过，并使用 `scripts/test_data_consistency.sh --json-summary` 验证数据平面一致性。
   - 在 `IMPLEMENTATION_SUMMARY.md` 或等价文档中，简要记录本 change 所覆盖的目录批次、主要删除/合并决策以及回归结果摘要，供后续 PR/变更引用。
