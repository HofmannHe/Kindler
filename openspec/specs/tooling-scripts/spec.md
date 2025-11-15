# tooling-scripts Specification

## Purpose
TBD - created by archiving change refactor-scripts-consolidation. Update Purpose after archive.
## Requirements
### Requirement: Script Discoverability
Inventory automation SHALL parse standardized metadata headers from every maintained script.
#### Scenario: Inventory enforces metadata contract
- **WHEN** `scripts/scripts_inventory.sh --markdown` runs
- **THEN** it parses `Description`, `Usage`, `Category`, `Status`, and optional `See also` headers from every `scripts/*.sh` entrypoint
- AND fails with a non-zero exit code if any required key is missing
- AND regenerates `docs/scripts_inventory.md` grouped by category with status counts
- AND `scripts/scripts_inventory.sh --check` fails whenever the checked-in Markdown is stale relative to regenerated output

### Requirement: Non-breaking Deprecation
Deprecated scripts SHALL continue to work while guiding users to canonical commands until explicitly removed in a documented phase-out.

#### Scenario: Run deprecated wrapper
- GIVEN `basic-test.sh` exists as a wrapper
- WHEN the script runs
- THEN it prints a deprecation notice pointing to `smoke.sh`
- AND it forwards args and exit code to the canonical command

### Requirement: Script Headers
Key scripts SHALL include a short header (Description/Usage/See-also) to reduce time-to-understand.
 
#### Scenario: Open a key script
- WHEN a developer opens `create_env.sh` or `haproxy_route.sh`
- THEN the header describes purpose, synopsis, and related commands

### Requirement: Canonical Lifecycle Commands
Documentation and examples SHALL prefer `scripts/cluster.sh start|stop|list` over legacy wrappers (`start_env.sh`, `stop_env.sh`, `list_env.sh`).

#### Scenario: Stop/Start example in README
- WHEN a user reads the Stop/Start examples in `README.md` and `README_CN.md`
- THEN the commands use `scripts/cluster.sh stop <env>` and `scripts/cluster.sh start <env>`
- AND no new examples recommend the legacy wrappers

### Requirement: Remove deprecated wrappers (batch 1)
The following deprecated wrappers MUST be removed after documentation updates:
- `scripts/haproxy_render.sh` → use `scripts/haproxy_sync.sh`
- `scripts/portainer_add_local.sh` → use `scripts/portainer.sh add-local`

#### Scenario: Wrapper not found
- WHEN a user tries to run `scripts/portainer_add_local.sh` or `scripts/haproxy_render.sh` after this change
- THEN the files are absent
- AND the canonical replacements are documented in `README.md` and `scripts/README.md`

### Requirement: Remove deprecated wrappers (batch 2)
The following deprecated wrappers MUST be removed after documentation updates and internal references are migrated:
- `scripts/fix_applicationset.sh` → `tools/fix_applicationset.sh`
- `scripts/fix_git_branches.sh` → `tools/fix_git_branches.sh`
- `scripts/fix_helm_duplicate_resources.sh` → `tools/fix_helm_duplicate_resources.sh`
- `scripts/fix_ingress_controllers.sh` → `tools/fix_ingress_controllers.sh`
- `scripts/fix_haproxy_routes.sh` → `tools/fix_haproxy_routes.sh`
- `scripts/debug_portainer.sh` → `tools/debug_portainer.sh`
- `scripts/registry.sh` → `tools/registry.sh`
- `scripts/reconfigure_host.sh` → `tools/reconfigure_host.sh`
- `scripts/argocd_project.sh` → `tools/argocd_project.sh`
- `scripts/project_manage.sh` → `tools/project_manage.sh`
- `scripts/start_reconciler.sh` → `tools/start_reconciler.sh`

#### Scenario: Tool wrapper not found
- WHEN a user tries to run any of the above removed wrappers
- THEN the files are absent in `scripts/`
- AND the tools exist under `tools/` with equivalent functionality
- AND READMEs point to the `tools/` paths

### Requirement: Remove deprecated wrappers (batch 3)
Deprecated wrappers SHALL be absent from the repository and documentation SHALL point to canonical replacements only.
#### Scenario: Wrapper commands unavailable
- **WHEN** a user runs `ls scripts/basic-test.sh scripts/monitor_test.sh scripts/start_env.sh scripts/stop_env.sh scripts/list_env.sh`
- **THEN** the files do not exist
- AND `docs/scripts_inventory.md`, `scripts/README.md`, `README.md`, and `README_CN.md` mention only `scripts/smoke.sh` and `scripts/cluster.sh` for basic tests/start-stop/list workflows

### Requirement: Single database helper (SQLite only)
All scripts, docs, and tests SHALL source `scripts/lib/lib_sqlite.sh`; the PostgreSQL helper must not exist.
#### Scenario: No lib_db.sh consumers
- **WHEN** a developer searches for `lib_db.sh`
- **THEN** the file is absent under `scripts/`
- AND active docs/tests source `scripts/lib/lib_sqlite.sh`
- AND `scripts/scripts_inventory.sh --check` would fail if a new reference to `lib_db.sh` appears

### Requirement: Regression harness
There SHALL be a scripted way to execute the mandated clean → bootstrap → create clusters → reconcile → smoke/tests pipeline with logging.

#### Scenario: Run full regression (scripted only)
- **WHEN** `scripts/regression.sh --full` runs (internally 调用 `tests/regression_test.sh --full`)
- **THEN** it performs `scripts/clean.sh --all`, `scripts/bootstrap.sh`, 以及 `scripts/reconcile_loop.sh --once`（从 SQLite 导入的 desired state 至少包含 ≥3 kind 与 ≥3 k3d 环境），并在业务集群全部在线后额外执行一次 `scripts/reconcile.sh --prune-missing` 以移除陈旧记录
- AND it enforces the ≥3 k3d / ≥3 kind check, creates any missing environments recorded in SQLite, and fails if 数量不足
- AND it executes `scripts/smoke.sh <env>` for every non-devops environment plus `bats tests` to cover 脚本级单元测试
- AND it automatically cleans up 临时 `test-script-*` 集群、写入 `logs/regression/<timestamp>/phase-*.log`，并把最新 `RECONCILE_SUMMARY` 和结果摘要追加到 `docs/TEST_REPORT.md`
- AND the command exits non-zero whenever 任何阶段需要人工干预或者脚本检测失败，确保“手工介入=回归失败”。

### Requirement: Declarative reconciliation runner
Scripts MUST provide a reconciliation entrypoint that reads desired cluster state from SQLite and converges actual infrastructure accordingly.

#### Scenario: Run reconciliation after clean
- **GIVEN** the SQLite `clusters` table contains rows for `dev`, `uat`, `prod`, `dev-a`, `dev-b`, `dev-c` (desired_state=`present`)
- **WHEN** `scripts/reconcile.sh --from-db` executes after `scripts/clean.sh --all`
- **THEN** each listed cluster is recreated (k3d/kind + Portainer + HAProxy + ArgoCD + Git branch) without manual `create_env.sh` calls
- AND reconciliation exits non-zero if any cluster cannot be restored.

#### Scenario: Prune stale records
- **WHEN** `scripts/reconcile.sh --prune-missing` runs and SQLite references `test-old` but no such cluster/context exists
- **THEN** the row for `test-old` is deleted (excluding the reserved `devops` row)
- AND the removal is logged in the reconciliation summary.

#### Scenario: Dry-run planning
- **WHEN** `scripts/reconcile.sh --dry-run` executes
- **THEN** it prints the actions it would take (create/delete/prune) without mutating clusters or SQLite
- AND returns non-zero if drift remains so that CI can block.

### Requirement: Regression harness invokes reconciliation
Regression tooling SHALL rely on the reconciliation runner instead of hard-coding environment creation order.

#### Scenario: Regression sequence
- **WHEN** `tests/regression_test.sh` runs
- **THEN** it performs `clean.sh`, `bootstrap.sh`, **invokes `scripts/reconcile.sh --from-db`**, validates that ≥3 kind and ≥3 k3d clusters exist, and only then continues with smoke/tests
- AND the reconciliation summary is appended to `docs/TEST_REPORT.md`.

### Requirement: Drift helpers expose machine-readable status
Diagnostics scripts SHALL produce structured output so automation can make decisions without parsing prose.

#### Scenario: db_verify exit codes
- **WHEN** `scripts/db_verify.sh` runs as part of reconciliation
- **THEN** it returns exit code `0` on success, `10` when clusters referenced in SQLite are missing, and `11` when actual resources exist but SQLite disagrees
- AND it writes an optional JSON summary (or clearly delimited text) that callers can parse.

### Requirement: Declarative workflow documentation
Official docs SHALL describe the clean → bootstrap → reconcile → validate lifecycle so operators know how to restore the system from scratch.

#### Scenario: README guidance
- **WHEN** a contributor reads README/README_CN/AGENTS/TESTING docs
- **THEN** there is an explicit section explaining that after destructive operations they must run `scripts/reconcile.sh --from-db` (or `--prune-missing`) to converge state before running smoke/regression tests.

### Requirement: Reconcile automation entrypoint
A dedicated script SHALL allow scheduled/looped reconciliation without duplicating business logic.

#### Scenario: Run reconcile loop
- **WHEN** `scripts/reconcile_loop.sh --interval 15 --max-runs 1` executes
- **THEN** it invokes `scripts/reconcile.sh --from-db` exactly once, respecting all existing flags (e.g., `--prune-missing`, `--dry-run`)
- AND prints a human summary + JSON payload to stdout
- AND exits non-zero if the underlying reconcile run fails
- AND documentation provides cron/systemd examples referencing this script

### Requirement: Reconcile audit log
Every reconcile execution SHALL append a structured JSON entry for auditing.

#### Scenario: Inspect last run
- **WHEN** `scripts/reconcile.sh --last-run` executes (after at least one reconcile)
- **THEN** it reads `logs/reconcile_history.jsonl`
- AND prints timestamp, exit status, action counts, and drift details of the latest run
- AND regression tests append that summary to `docs/TEST_REPORT.md`

### Requirement: Lifecycle DB verification
Lifecycle scripts SHALL immediately verify SQLite vs actual state after create/delete flows.

#### Scenario: Create env triggers verify
- **WHEN** `scripts/create_env.sh -n dev-a` completes without `SKIP_DB_VERIFY=1`
- **THEN** it runs `scripts/db_verify.sh --json-summary`
- AND fails (non-zero) if the verification reports missing clusters or stale rows
- AND emits a warning whenever CSV defaults are used because SQLite was unavailable

### Requirement: Subsystem retry policy
Portainer, ArgoCD, and Git helpers SHALL implement bounded retries and bubble failures.

#### Scenario: Portainer endpoint fails repeatedly
- **WHEN** `scripts/portainer.sh add-endpoint dev ...` receives non-2xx responses
- **THEN** it retries with exponential/backoff up to the documented limit
- AND if still failing, it exits non-zero with actionable logs
- AND callers (e.g., `create_env.sh`, `reconcile.sh`) abort with the same failure instead of continuing silently

### Requirement: Script Audit Report
Script evaluations SHALL be captured in an auto-generated Markdown report for operators.
#### Scenario: Audit report updated
- **WHEN** `docs/scripts_inventory.md` is opened after running `scripts/scripts_inventory.sh --markdown`
- **THEN** it lists each maintained script with columns for Description, Usage, Category, and Status
- AND includes a summary section showing counts per category and status to highlight redundant/unneeded entries during audits

### Requirement: Chinese-First Communication
面向仓库贡献者的官方文档与脚本输出 MUST 默认使用中文描述，除专业术语、命令、路径、标识符外不得切换到其他语言。

#### Scenario: Documentation language guidance
- **GIVEN** 贡献者阅读 README、README_CN、openspec/AGENTS.md 或 scripts/README.md
- **WHEN** 文档描述流程、注意事项或沟通规范
- **THEN** 文本主体使用中文（专业术语保持英文原样）
- AND 明确说明“默认中文交流，专业术语保持英文”这一约定
- AND 有新的文档章节/脚本帮助输出该提醒时也遵循同样规则

### Requirement: Scripted regression plan documentation
回归测试计划文档 MUST 说明“全部步骤通过仓库脚本/代码执行，禁止手动操作”。

#### Scenario: Regression playbook describes script-only flow
- **WHEN** 贡献者阅读 `docs/REGRESSION_TEST_PLAN.md`（并在 `docs/REGRESSION_TEST.md` / `docs/TESTING_GUIDE.md` 中看到引用）
- **THEN** 文档列出 clean → bootstrap → reconcile → smoke/tests → 数据一致性 → 自动清理的脚本化步骤
- AND 明确入口命令（`scripts/regression.sh --full` / `tests/regression_test.sh --full`）、支持的 CLI 参数、日志位置，以及“出现手动操作即宣告失败”的判定
- AND 该文档保持与脚本实现同步，`openspec validate` 会在变更结束前通过。

