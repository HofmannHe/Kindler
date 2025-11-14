## Why
- 当前 `main` 工作树存在 50+ 已跟踪改动与 20+ 未跟踪文件（参见 `git diff --stat` 与 `git status`），覆盖 README、脚本、manifests、openspec 乃至日志；既有增删改混杂，又缺乏变更来源说明，无法直接提交/合并。
- 这些改动跨越多个领域（文档、Spec、工具脚本、HAProxy/ArgoCD 配置等），其中部分属于历史提案（如 `refactor-scripts-consolidation`）但目录已被删除，缺少映射关系，难以判断哪些需要保留。
- 根目录直接开发违反“必须在 worktrees/ 下用分支 + `KINDLER_NS` 隔离”的仓库约束，也阻塞了新的 PR：若不先梳理、迁移与验证，就无法安全地恢复可用的 `main`。

## What Changes
1. 建立“工作树卫生”梳理计划：分类列出现有 diff（按文档/脚本/openspec/测试/运行时工件），标记来源与期望处理方式（保留、拆分、丢弃、迁入 worktree）。
2. 设计并执行迁移流程：创建新的 worktree 分支（e.g. `worktrees/stabilize-main`），在其下逐项应用需要保留的改动，确保 `main` 回到干净状态；同时补充缺失的 openspec 变更目录与 spec delta。
3. 在清理过程中补齐验证：针对脚本改动运行 `tests/regression_test.sh`（必要时 `--full`）、`bats tests`、`scripts/smoke.sh`，并更新 `docs/TEST_REPORT.md`；完成后输出 PR 摘要与合并步骤。

## Impact
- `docs/*` 与 README：需要重新审视数千行 diff，决定合并策略并补全中英文同步要求。
- `scripts/*`、`tests/*`、`manifests/*`：需要重新确认每个改动的动机、是否符合最新 spec，并在 worktree 中验证。
- `openspec/*`：恢复/更新被删除的 change 目录，新增 “stabilize-main-worktree” 计划，补充 tooling-scripts 规范。
- 工作流：引入显式的污点梳理与 PR 准备步骤，确保后续贡献遵守 worktree + KINDLER_NS 要求。
