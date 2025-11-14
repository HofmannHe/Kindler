## ADDED Requirements

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
