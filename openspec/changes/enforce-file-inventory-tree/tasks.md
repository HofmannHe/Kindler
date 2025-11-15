1. - [ ] 梳理并建模“文件清单树”目标
   - 阅读 `docs/FILE_INVENTORY.md`、`examples/FILE_INVENTORY.md`、`FILE_INVENTORY_ALL.md` 与相关脚本，明确当前“文档清单 + 全局白名单”的职责边界。
   - 设计从仓库根目录出发的“文件清单树”模型：哪些目录需要本地 FILE_INVENTORY/FILE_PLAN，哪些目录可以通过上层条目概括（例如仅包含临时工件或第三方脚本）。
   - 在本 change 目录记录初步树形结构草图，用于后续实现与评审（可直接放在本文件或追加到 proposal 末尾）。

2. - [ ] 更新 tooling-scripts 规格以支持层次化文件清单
   - 在 `openspec/changes/enforce-file-inventory-tree/specs/tooling-scripts/spec.md` 中：
     - 为“层次化文件清单树”新增 ADDED Requirements，明确：
       - 从仓库根目录开始，每一级目录可以通过 FILE_INVENTORY/FILE_PLAN 描述自身与子目录的用途与边界。
       - 所有长期存在的文件/目录至少在一处清单中拥有 Purpose/Owner/Scope 的简要说明。
       - `FILE_INVENTORY_ALL.md` 继续作为“git ls-files 严格白名单”，但脚本需要能从清单树推断每个路径的归属。
     - 为“目录规模审计（Phase 1）”新增 Requirement，要求提供轻量脚本以 WARN 方式报告单目录文件数超过阈值的情况。

3. - [ ] 为关键子树新增局部 FILE_INVENTORY
   - 在不破坏现有检查脚本的前提下，为至少以下目录添加局部清单：
     - `webui/FILE_INVENTORY.md`：描述 README 与后续需要长期维护的说明类文件/子目录。
     - `tools/FILE_INVENTORY.md`：对主要工具脚本/子目录提供 Purpose/Owner/Scope，便于识别是否仍然必要。
   - 按 reduce-report-noise 约束，避免为一次性报告新增 Markdown 文件；仅在确属“长期存在的规范/结构性文档”时才创建对应清单。

4. - [ ] 实现并接入文件清单树与目录规模审计脚本
   - 实现一个新的脚本（例如 `scripts/file_tree_audit.sh` 或等价名字）：
     - 基于 `git ls-files` 构建目录树并统计每个目录的文件数量。
     - 输出简洁的中文摘要，列出超过默认阈值（如 15 个文件）的目录，并为后续重构提供参考。
     - 默认以 WARNING 形式运行且不依赖 Docker/k3d/kind/网络，仅作为本地/CI 的结构审计工具。
   - 在 `scripts/scripts_inventory.sh --check` 中接入该脚本和新增的局部 FILE_INVENTORY 检查，保持原有行为先通过再追加新的检查步骤。

5. - [ ] 运行 openspec 与脚本自检
   - 执行 `openspec validate enforce-file-inventory-tree --strict`，确保 proposal/tasks/spec delta 结构正确、引用一致。
   - 在本阶段实现结束时，至少成功运行：
     - `scripts/scripts_inventory.sh --check`
     - `scripts/file_inventory_all.sh --check`
   - 记录未来扩展建议：如何逐步将“目录文件数上限”从 WARNING 收紧为强制约束，以及如何在后续变更中分批重构目录结构以满足 ≤15 文件/目录的目标。

