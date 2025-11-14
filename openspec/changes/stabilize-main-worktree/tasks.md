1. - [x] 运行 `git status -sb`、`git diff --stat`、`rg` 等命令，将当前所有改动按类别（文档、脚本、openspec、manifests、测试、运行日志）列成清单，记录意图/疑问。
2. - [x] 明确每个类别的处理策略（保留/拆分/丢弃/待确认），并把对应关系写入笔记，必要时补充缺失的 change 目录或还原被误删的 openspec 文件。
3. - [x] 创建 `worktrees/stabilize-main` 工作树与 `feature/stabilize-main` 分支，设置 `KINDLER_NS=stabilize-main`，确保后续脚本/测试在隔离环境执行。
4. - [x] 在新工作树中按类别迁移需要保留的改动（含 `README_EN`/中文同步、脚本、manifests、Spec）；同时让根目录 `main` 回到干净状态（仅保留必要文件）。
5. - [x] 在工作树中跑验证矩阵：`scripts/clean.sh --all` → `scripts/bootstrap.sh` → `scripts/reconcile_loop.sh --once --prune-missing` → `tests/regression_test.sh --full`（含 smoke、bats、db_verify），并把结果摘要更新到 `docs/TEST_REPORT.md`。
6. - [ ] 准备并提交 PR：整理 commit（按类别清晰划分，遵循 Conventional Commits）、更新 `CHANGELOG`/spec 状态、撰写合并说明，最终通过审查并合入 `main`；完成后删除临时工作树并确认 `main` 仍干净。
