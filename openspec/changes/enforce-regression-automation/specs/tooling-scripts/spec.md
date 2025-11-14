## MODIFIED Requirements

### Requirement: Regression harness
There SHALL be a scripted way to execute the mandated clean → bootstrap → create clusters → reconcile → smoke/tests pipeline with logging.

#### Scenario: Run full regression (scripted only)
- **WHEN** `scripts/regression.sh --full` runs (internally 调用 `tests/regression_test.sh --full`)
- **THEN** it performs `scripts/clean.sh --all`, `scripts/bootstrap.sh`, 以及 `scripts/reconcile_loop.sh --once`（从 SQLite 导入的 desired state 至少包含 ≥3 kind 与 ≥3 k3d 环境），并在业务集群全部在线后额外执行一次 `scripts/reconcile.sh --prune-missing` 以移除陈旧记录
- AND it enforces the ≥3 k3d / ≥3 kind check, creates any missing environments recorded in SQLite, and fails if 数量不足
- AND it executes `scripts/smoke.sh <env>` for every non-devops environment plus `bats tests` to cover 脚本级单元测试
- AND it automatically cleans up 临时 `test-script-*` 集群、写入 `logs/regression/<timestamp>/phase-*.log`，并把最新 `RECONCILE_SUMMARY` 和结果摘要追加到 `docs/TEST_REPORT.md`
- AND the command exits non-zero whenever 任何阶段需要人工干预或者脚本检测失败，确保“手工介入=回归失败”。

## ADDED Requirements

### Requirement: Scripted regression plan documentation
回归测试计划文档 MUST 说明“全部步骤通过仓库脚本/代码执行，禁止手动操作”。

#### Scenario: Regression playbook describes script-only flow
- **WHEN** 贡献者阅读 `docs/REGRESSION_TEST_PLAN.md`（并在 `docs/REGRESSION_TEST.md` / `docs/TESTING_GUIDE.md` 中看到引用）
- **THEN** 文档列出 clean → bootstrap → reconcile → smoke/tests → 数据一致性 → 自动清理的脚本化步骤
- AND 明确入口命令（`scripts/regression.sh --full` / `tests/regression_test.sh --full`）、支持的 CLI 参数、日志位置，以及“出现手动操作即宣告失败”的判定
- AND 该文档保持与脚本实现同步，`openspec validate` 会在变更结束前通过。
