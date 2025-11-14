## ADDED Requirements

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
