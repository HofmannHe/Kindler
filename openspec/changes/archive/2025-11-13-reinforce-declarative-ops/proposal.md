# Proposal: Reinforce Declarative Operations

## Why
- 当前虽然有 `reconcile.sh`，但只能手动触发，无法持续调和；一旦人工遗忘，就会在回归前出现 Portainer/SQLite 漂移。
- 调和/清理的结果缺少统一日志与审计，`docs/TEST_REPORT.md` 只能记录人为执行的结果，难以及时发现失败。
- `create_env.sh`/`delete_env.sh` 等生命周期脚本在调用 Portainer/ArgoCD/Git 时对错误处理与重试不一致，常见漂移只能依赖后续 `cleanup_nonexistent_clusters.sh` 补救。
- CSV fallback 仍会被脚本使用，声明式数据源（SQLite）没有被强制执行；创建/删除后也不会立即运行 `db_verify` 检测漂移。

## What Changes
- 增加“可定时”调和入口（可作为 cron/systemd 示例），循环调用 `reconcile.sh --from-db` 并记录日志，同时提供 `--once`/`--interval` 选项便于开发者控制。
- 将 `reconcile.sh`/新入口的 JSON summary 统一落盘（JSONL），并提供 `scripts/reconcile.sh --last-run` 或独立 CLI 读取最近结果，以便回归/运维引用。
- 生命周期脚本在成功执行后自动运行 `db_verify.sh --json-summary`，如发现漂移立即失败；同时减少对 CSV 的 fallback，并对直接访问 CSV 的路径输出显式警告。
- Portainer/ArgoCD/Git 同步步骤增加轻量重试与失败短路，确保脚本在子系统未完成时不会静默继续。
- 更新 README/README_CN/AGENTS/TESTING 文档，描述“clean→bootstrap→(可选自动)reconcile→validate”流程，以及如何启用/禁用调和循环。

## Impact
- Specs: `tooling-scripts`
- Code: `scripts/reconcile.sh`, 新的循环入口脚本、`create_env.sh`, `delete_env.sh`, Portainer/ArgoCD/Git 辅助脚本, 相关文档
- Tests: regression harness 需验证调和日志与自动校验
