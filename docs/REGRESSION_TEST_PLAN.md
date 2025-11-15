# 回归测试计划（脚本化）

本计划定义 Kindler 项目“零手动介入”的回归测试流程。所有动作必须由仓库脚本或自动化代码完成；一旦需要手动执行 kubectl、curl 或 UI 操作，即视为回归失败。

## 统一入口

| 命令 | 说明 |
| ---- | ---- |
| `scripts/regression.sh --full` | 首选入口，封装 `tests/regression_test.sh` 并强制 `--full` 模式；通过 stdout/JSON 暴露回归摘要，供 PR/CI 使用 |
| `tests/regression_test.sh [options]` | 调试入口，可使用 `--skip-clean`、`--skip-bootstrap`、`--clusters dev,uat`、`--skip-smoke`、`--skip-bats` 等参数 |

> 所有日志默认写入 `logs/regression/<timestamp>/`，回归脚本会通过 stdout/JSON 输出最新的 Reconcile Snapshot、smoke 结果与关键 JSON 摘要，方便直接复制到 PR/CI 描述。历史上曾使用 `docs/TEST_REPORT.md` 等文档记录完整回归结果；现在推荐直接依赖日志与 JSON 摘要，并仅保留 `docs/history/REGRESSION_TEST_REPORT_20251024.md` 作为代表性案例，不再为新的回归轮次创建额外 Markdown 报告。

## 流程拆解

| 阶段 | 脚本/命令 | 关键校验 | 日志文件 |
| ---- | -------- | -------- | -------- |
| 1. 清理 | `scripts/clean.sh --all` | 释放 devops/业务集群、Portainer/HAProxy 容器 | `phase1-clean.log` |
| 2. 引导 | `scripts/bootstrap.sh` | devops 集群 + HAProxy/Portainer/ArgoCD 无报错 | `phase2-bootstrap.log` |
| 3. 调和 | `scripts/reconcile_loop.sh --once` | 自动创建来自 SQLite 的 ≥3 k3d + ≥3 kind 集群，失败即退出 | `phase3-reconcile.log` |
| 4. 迁移校验 | `scripts/test_sqlite_migration.sh` | SQLite 结构、`devops` 记录齐全 | `regression.log` |
| 5-6. 测试集群 | `scripts/create_env.sh -n test-script-k3d/-p k3d` & `-p kind` | `kubectl get nodes` 成功；自动写入 SQLite | `phase5/phase6` |
| 7. SQLite ↔ 集群一致性 | `scripts/cleanup_nonexistent_clusters.sh`、`scripts/sync_applicationset.sh` | `test-script-*` 在 SQLite 中存在；ApplicationSet 仅包含实际集群 | `regression.log` |
| 8. Smoke + 一致性脚本 | `scripts/smoke.sh <env>`（遍历 SQLite/CSV 中除 devops 外的所有环境）+ `scripts/test_data_consistency.sh --json-summary` | Portainer 301 / HTTPS 200 / whoami 200；`CONSISTENCY_SUMMARY` 为 success | `regression.log`（stdout/JSON 摘要可复制到 PR/CI） |
| 9. SQLite 验证 | `scripts/db_verify.sh --json-summary` | 退出码 0；`DB_VERIFY_SUMMARY` 标记一致 | `regression.log` |
| 10. 脚本单测 | `bats tests` | 所有 `.bats` 文件通过 | `regression.log` |
| 11. 收尾 | 自动删除 `test-script-*`，记录结果摘要 | `regression.log` |

> 若需要清理陈旧的数据库记录，可在所有业务集群成功创建后额外执行 `scripts/reconcile.sh --prune-missing`（此时集群已存在，不会被误删）。

## 判定规则

1. 任意阶段非零退出，或需要额外手动命令才能继续，即视为回归失败。
2. Reconcile 后若 k3d/kind 数量不足（≥3），脚本立即失败并保留日志供排障。
3. smoke/bats/db-verify/test-data-consistency 任一失败，必须修复根因后重新运行 `scripts/regression.sh --full`。
4. 成功运行后，应在以下位置找到回归摘要：
   - `logs/regression/<timestamp>/regression.log` 中包含最新 Reconcile Snapshot（含 `RECONCILE_SUMMARY` JSON）与烟囱/一致性脚本结果；
   - `logs/reconcile_history.jsonl` 中追加了本次 `scripts/reconcile.sh` 执行的结构化条目（可通过 `scripts/reconcile.sh --last-run [--json]` 查看）；
   - 必要时可从这些 stdout/JSON 摘要中复制 `CONSISTENCY_SUMMARY` / `DB_VERIFY_SUMMARY` 等关键信息到 PR/CI 描述；如需文字化报告，可参考 `docs/history/REGRESSION_TEST_REPORT_20251024.md` 的结构自行整理，而不是追加新的 `*_TEST_REPORT.md` 文件。

## 参数速查

```bash
# 完整流程
scripts/regression.sh --full

# 跳过清理（例如刚执行过 clean）
scripts/regression.sh --skip-clean

# 列出或只回归特定业务集群（影响 smoke/test-data）
scripts/regression.sh --clusters dev,uat

# 调试：保留 smoke/bats，但跳过 bootstrap
tests/regression_test.sh --skip-bootstrap
```

> `--clusters` 会与 SQLite (首选) / `config/environments.csv` 交叉校验，若传入不存在的名称会直接失败，防止遗漏。

## 日志与审计

- `logs/regression/<timestamp>/regression.log`：主输出；`phase*.log`：各阶段 STDOUT/STDERR。
- `logs/reconcile_history.jsonl`：长期审计日志，可通过 `scripts/reconcile.sh --last-run [--json]` 获取最新条目，并在 PR/CI 中引用。
- 额外系统日志（Docker、k3d、kind、Portainer API）无需手工保存，除非脚本失败时自动 tail 的 20 行不足以定位问题。

## 历史案例（参考）

- 典型完整回归报告：`docs/history/REGRESSION_TEST_REPORT_20251024.md`。
- 其他 `REGRESSION_TEST_*` / `*_TEST_REPORT` 等 Markdown 报告已在 `shrink-file-inventory-tree` 变更中收敛为上述单个代表性案例和本测试计划；新的回归轮次只需依赖日志与 JSON 摘要，而不是新增报告文档。

## 故障排查建议

1. **调和失败**：查看 `phase3-reconcile.log`，确认 SQLite `clusters` 表是否齐全（可执行 `scripts/db_verify.sh --json-summary`）。
2. **Smoke 失败**：检查 HAProxy network/域名是否已由 `scripts/haproxy_sync.sh --prune` 正确生成；必要时复查 `config/clusters.env` 的 `BASE_DOMAIN`。
3. **bats 失败**：使用 `bats --filter <pattern> tests` 定位具体 .bats 文件，修复脚本或数据后重新运行 `scripts/regression.sh --full`。
4. **资源残留**：脚本退出后会自动调用 `scripts/delete_env.sh -n test-script-...`，若仍存在可再次运行 `scripts/clean.sh --all` 并重试。

该文档与 `tests/regression_test.sh`、`scripts/regression.sh` 同步维护；提交前必须确保 `openspec validate enforce-regression-automation --strict` 通过。
