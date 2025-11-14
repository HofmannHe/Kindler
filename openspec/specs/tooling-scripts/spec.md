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

#### Scenario: Run full regression
- **WHEN** `scripts/regression.sh --full` executes
- **THEN** it performs `scripts/clean.sh`, `scripts/bootstrap.sh`, creates every environment defined in `config/environments.csv` (enforcing ≥3 kind and ≥3 k3d)
- AND runs `scripts/reconcile.sh`, `scripts/smoke.sh <env>` for each environment, and `bats tests`
- AND writes logs per phase plus an appended entry in `docs/TEST_REPORT.md`

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

