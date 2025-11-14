# 脏工作树改动清单（截至当前执行）

| 类别 | 代表文件 | 主要意图/风险 | 处理建议 |
| ---- | -------- | ------------- | -------- |
| README/文档 | `README.md`, `README_CN.md`, `README_EN.md`, `docs/REGRESSION_TEST*.md`, `docs/TEST_REPORT.md`, `docs/WEBUI_NEW_ISSUES_DIAGNOSIS.md` 等 | 回归自动化、中文优先、WebUI 路由修复相关说明大量更新，且 `docs/TEST_REPORT.md` 追加了多轮 smoke 输出 | 保留结构化内容；`README_CN` 与英文版同步校对；`docs/TEST_REPORT.md` 缩减为摘要，并将动辄上千行的运行日志移出版本控制 |
| openspec 与规范 | `openspec/AGENTS.md`, `openspec/specs/*`, 新增 change 目录 `enforce-regression-automation`、`fix-webui-routing`、`stabilize-main-worktree`，以及 archive 目录 | 记录已批准的自动化/路由变更，但 live 目录 `refactor-scripts-consolidation` 与 `update-haproxy-sync-sqlite` 被删除 | 确认 archive 目录 `openspec/changes/archive/2025-11-12-refactor-scripts-consolidation` 与 `2025-11-11-update-haproxy-sync-sqlite` 已完整保留，可在 PR 中正式删除对应 live 目录并跟踪 archive |
| Scripts/Tools | `scripts/*.sh`（bootstrap/reconcile/haproxy/smoke/...），`scripts/lib/lib.sh`，`scripts/regression.sh`，`scripts/test_sqlite_migration.sh` 等；`tools/git/*.sh`, `tools/dev/lint.sh` | 主要是 SQLite 驱动 HAProxy、KINDLER_ROOT 支持、regression harness、Git helper 清理 | 在 worktree 中保留，逐个运行 bats/回归确认；按功能拆 commit，记录高风险脚本的验证日志 |
| Manifests | `manifests/argocd/infrastructure-applicationset.yaml` 被删除、新增 `.example` | 希望使用脚本生成 ApplicationSet，避免手动配置漂移 | 确认 README/Docs 中包含生成步骤；在 worktree 中只保留 `.example`，移除旧版本 |
| Tests | `tests/regression_test.sh`, `tests/cleanup_test_clusters.sh`, 新增 `tests/quick_verify.sh`、`tests/db_verify.sh` 等 | 覆盖回归自动化与 SQLite 验证 | 在 worktree 中保留，运行 `bats tests` 与 `tests/regression_test.sh --full` 验证 |
| 运行期工件 | `logs/reconcile_history.jsonl*`, 巨大的 `docs/TEST_REPORT.md`, `manifests/argocd/infrastructure-applicationset.yaml.example`（未跟踪版本） | 日志/报告会在每次运行时变化，不应纳入 git 版本；example 需要纳入 | 将日志加入 `.gitignore` 并从 repo 中删除；`docs/TEST_REPORT.md` 仅保留摘要；`.example` 文件纳入版本控制 |
