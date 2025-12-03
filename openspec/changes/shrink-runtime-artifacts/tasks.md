1. - [x] 梳理并确认需要收缩的运行时/实验文件
   - [x] 使用 `rg "phase2-attempt" webui/backend` 和 `rg "broken" tests` 等命令，确认实验/损坏文件的分布范围。
   - [x] 复核 `FILE_INVENTORY_ALL.md`，确认这些文件已被列入严格白名单，删除时需要同时更新清单。
2. - [x] 更新 tooling-scripts 规格，增加运行时/敏感产物收缩要求
   - [x] 在 `openspec/changes/shrink-runtime-artifacts/specs/tooling-scripts/spec.md` 中添加 `## ADDED Requirements` 小节，描述对实验实现、敏感配置和 broken 测试文件的约束。
   - [x] 运行 `openspec validate shrink-runtime-artifacts --strict`，确保规格变更合法。
3. - [x] 清理 WebUI 后端实验文件
   - [x] 删除 `webui/backend/app/api/clusters.py.phase2-attempt` 与 `webui/backend/app/services/db_service.py.phase2-attempt`。
   - [x] 更新 `FILE_INVENTORY_ALL.md`，移除对应条目，并运行 `scripts/file_inventory_all.sh --check` 确认通过。
4. - [x] 处理含敏感配置的 git.env
   - [x] 从版本库移除 `config/git.env`（保留本地未提交版本），确保 `.gitignore` 中有相应规则。
   - [x] 确认/更新 `config/git.env.example`，保证示例字段完整，文档中明确说明复制流程。
5. - [x] 精简或归档显式损坏的测试脚本
   - [x] 评估 `tests/services_test.sh.broken` 的实际用途：若仍有价值则修复并接入 `tests/run_tests.sh`/`scripts/regression.sh`，否则迁移到 `docs/history/` 或删除。
   - [x] 更新 `FILE_INVENTORY_ALL.md` 与相关文档，保持测试入口清晰。
6. - [x] 统一验证与文档更新
   - [x] 运行 `scripts/file_inventory_all.sh --check` 与 `scripts/file_tree_audit.sh --max-per-dir 15`，确保没有幽灵文件或未经审计的新增文件。
   - [x] 最少执行一次 `tests/run_tests.sh services` 或 `scripts/regression.sh --full` 中的子集，确认 WebUI 与核心脚本行为不受影响。
   - [x] 在适当的文档位置（例如 `docs/IMPLEMENTATION_SUMMARY.md` 或 `docs/WEBUI_FIX_SUMMARY.md`）补充一段简短说明，记录本次运行时产物收缩的决策与范围。
