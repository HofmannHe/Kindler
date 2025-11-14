# Design: Enforce Declarative Reconciliation

## Overview
We extend the existing script toolchain so the desired cluster state defined in SQLite drives actual resources. The centerpiece is a reconciliation runner that reads `clusters` rows, compares them against reality (k3d/kind clusters, Portainer endpoints, HAProxy routes, ArgoCD Secrets/ApplicationSet), and performs corrective actions. Regression/test pipelines call this runner to guarantee drift-free environments before validation.

## Components
1. **Reconcile Runner (`scripts/reconcile.sh` or new `scripts/reconciler.sh once`)**
   - Enumerates rows from SQLite where `desired_state='present'`.
   - For each row:
     - If cluster missing → call `create_env.sh -n <name> -p <provider>` with ports from DB.
     - If cluster exists but DB says `desired_state='absent'` → call `delete_env.sh`.
     - Ensure Portainer/HAProxy/ArgoCD/Git state matches DB by reusing existing sub-commands.
   - Supports `--prune-missing` to delete DB rows whose clusters are absent and `--dry-run` for CI preview.
   - Emits structured summary for docs/tests.

2. **Drift Detection Enhancements**
   - `db_verify.sh` gains machine-readable exit codes for: OK, cluster-missing, state-mismatch.
   - Reconciler consumes these helpers to avoid duplicating logic.

3. **Regression Harness Updates**
   - After `clean.sh` + `bootstrap.sh`, call `scripts/reconcile.sh --from-db` to recreate ≥3 kind and ≥3 k3d clusters automatically (no hard-coded CSV loop).
   - Capture reconciliation logs in `/tmp/kindler_reconcile.log` and append a condensed summary to `docs/TEST_REPORT.md`.

4. **Documentation & Instructions**
   - README/README_CN/AGENTS/TESTING docs describe the declarative flow: “clean → bootstrap → reconcile → validate”.
   - Provide troubleshooting guidance: e.g., run `scripts/reconcile.sh --prune-missing` after deleting clusters manually.

## Data Flow
```
SQLite clusters table
   │
   │   (select name, provider, desired_state, ports)
   ▼
Reconciler loop ──┬─> create_env.sh / delete_env.sh (ensures k3d/kind + Portainer/HAProxy/ArgoCD/Git)
                  └─> db_verify.sh (detect drift) → optional prune
```

## Failure Handling
- Each per-cluster action runs with retries and rolled-up exit status to avoid aborting the entire reconciliation on the first failure.
- Dry-run mode prints planned actions without executing them (useful before aggressive cleanup).
- Regression harness fails fast if reconciliation cannot restore the mandated set (prevents false-positive smoke results).

## Testing Strategy
- Unit level: shellcheck + targeted tests for new script flags.
- Integration: extend `tests/regression_test.sh` to expect reconciliation logs and verify the cluster count requirement.
- Manual validation: run `clean.sh --all`, then `scripts/reconcile.sh --from-db` and ensure DB + actual resources match via `db_verify.sh` + `test_data_consistency.sh`.
