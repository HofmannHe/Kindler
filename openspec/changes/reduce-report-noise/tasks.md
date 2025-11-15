1. - [ ] 梳理当前仓库中的报告与日志文件
   - 使用 `find`/`rg` 对根目录与 `docs/`、`logs/` 进行清单梳理，按类型分组：
     - 长期架构/规范文档（保留，例如 README/ARCHITECTURE/REGRESSION_TEST_PLAN 等）。
     - 测试/实现过程报告（候选迁移到 `docs/history/` 或删除）。
     - 日志与回归输出（`logs/**/*.log`、`full_regression_*.log`、`webui_e2e*.log` 等）。
   - 在本 change 下补充一份 `inventory.md` 或在 proposal 末尾附录记录清单与初步建议。

2. - [ ] 更新 tooling-scripts 规格以反映新的报告与文件清单策略
   - 在 `openspec/changes/reduce-report-noise/specs/tooling-scripts/spec.md` 中：
     - 为“测试报告持久化策略”新增 ADDED Requirements，明确：
       - 默认不将测试结果追加到 `docs/TEST_REPORT.md`。
       - 推荐通过 PR/CI 附上测试摘要，而不是创建新的 Markdown 报告文件。
     - 为“日志与构建产物”新增 Requirements，要求 `logs/**/*.log` 不得提交到仓库，且 `.gitignore` 涵盖对应模式。
     - 调整现有与 `docs/TEST_REPORT.md` 强绑定的 Requirements，将其重写为“生成可复制的摘要（stdout/JSON），供 PR/CI 使用”，不再强制更新文档文件。
     - 保留并强化 `docs/scripts_inventory.md` 作为“核心脚本审计报告”，要求在脚本变更后保持同步更新。
     - 新增“文档文件清单与正交边界”相关 Requirements，要求维护 `docs/FILE_INVENTORY.md`、提供检查脚本并在评审中执行“内容正交性”审查。

3. - [ ] 对 AI/自动化助手行为增加 openspec 约束
   - 在 tooling-scripts 的 delta 中增加场景：
     - 说明 AI 助手在运行脚本和测试时，**默认只在对话中**用简洁中文说明结果；
     - 除非用户显式要求，否则不得自动创建新的 `*_REPORT.md` / `FINAL_*.md` 等文件；
     - 若用户要求生成报告文件，需遵守本 change 定义的路径和命名规范，并尽量引用已有规范文档而不是重复描述。

4. - [ ] 为后续代码与文档清理准备规范依据
   - 在 specs 调整完成并通过 `openspec validate reduce-report-noise --strict` 后：
     - 在后续实现阶段，分 PR 删除已提交的日志文件，并在 `.gitignore` 中阻止未来同类文件被提交。
     - 设计并创建 `docs/FILE_INVENTORY.md`：按“架构/测试计划/操作手册/规范/历史案例”等分类，对根目录和 `docs/` 下需要长期保留的文档逐一说明用途与边界。
     - 实现并接入 `scripts/file_inventory.sh --check`（或复用现有脚本），将未在清单中的 Markdown 文件视为“待迁移/待删除”，用于驱动后续分批清理与迁移。
     - 为“将重要过程报告迁移到 docs/history 或删除”的工作预留任务占位符，避免与其他 change 冲突。

5. - [ ] 运行 openspec 验证
   - 执行 `openspec validate reduce-report-noise --strict`，确保本变更的 proposal/tasks/spec delta 结构正确、引用一致。
   - 根据验证输出修正 Requirements/Scenario 标题、引用路径等问题，保证在实现前规格自洽。
