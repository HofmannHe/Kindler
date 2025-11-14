## Overview
`main` 当前包含大规模未整理的改动，需要一个分阶段计划来：
1. **评审**：明确每份 diff 的来源、意图与相互依赖，避免误删或重复实现。
2. **迁移**：把需要保留的变更迁入专用 worktree + feature 分支，恢复 `main` 的可部署性。
3. **验证与合并**：在隔离分支中跑完既定脚本/测试，生成可信日志，再提 PR。

## Change Breakdown
| 区域 | 代表文件 | 风险 | 处理策略 |
| ---- | -------- | ---- | -------- |
| 文档/README | `README*.md`, `docs/*` | 中英文不同步、测试报告大量追加 | 对照最新规范，确认内容是否仍适用；必要时拆分为独立 commit，并更新 `README_EN` 与中文版本。 |
| 脚本 | `scripts/*.sh` | 核心逻辑变更（bootstrap/reconcile/haproxy 等），易影响集群生命周期 | 逐文件复盘 commit 意图，结合 `tests/regression_test.sh` 与 `bats` 验证；对高风险脚本先写简要笔记。 |
| Spec/openspec | `openspec/changes/*`, `openspec/specs/*` | 已有提案被删除或未归档 | 恢复必要的 change 目录，确保每项改动都有任务清单与 spec delta；新的计划放在 `stabilize-main-worktree`。 |
| manifests | `manifests/argocd/*` | ApplicationSet 被删除/替换，可能导致 GitOps 不一致 | 将当前生成的 example 与实际 manifest 对比，确认删除是否合理。 |
| 工件 | `logs/`, `docs/TEST_REPORT.md` 大量自动输出 | 容易把一次测试的结果混进 PR | 记录必要摘要，其余日志移动到 `.gitignore` 或清理出版本控制。 |

## Process
1. **分类评审**：使用 `git status`, `git diff --stat`, `rg`, `ls` 等命令生成分组清单，写入 change tasks/notes；对于来历不明的改动，联系原作者或在文档备注。
2. **建立 worktree**：`mkdir -p worktrees && git worktree add worktrees/stabilize-main feature/stabilize-main`，在该目录设置 `KINDLER_NS=stabilize-main`，仅在此处运行脚本/测试。
3. **分批迁移**：按类别 cherry-pick 或重新实现需要保留的改动；不确定的内容先搁置或新建 follow-up proposal；确保 `main` revert 到上一次可部署状态。
4. **验证矩阵**：
   - `tests/regression_test.sh --full`（若时间受限可先 `--skip-clean --skip-bootstrap` 预检）。
   - `bats tests`, `scripts/smoke.sh <env>`（SQLITE≥3 kind/k3d）。
   - `scripts/reconcile_loop.sh --once --prune-missing`.
   - 文档检查：`README_CN` vs `README_EN`。
5. **PR 准备**：在 feature 分支更新 `CHANGELOG` / `docs/TEST_REPORT.md` 摘要，生成 diff 说明，最终通过 PR 合并 `main`。
