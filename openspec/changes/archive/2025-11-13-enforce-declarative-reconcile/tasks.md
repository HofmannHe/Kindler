# Tasks: Enforce Declarative Reconciliation

1. **Reconcile Runner Foundations**
   - [x] 1.1 Extend `scripts/reconcile.sh` (or add a new entrypoint) to read SQLite clusters, diff desired vs actual, and emit a per-cluster plan.
   - [x] 1.2 Support actions: create missing clusters, delete rows marked absent, and prune DB rows whose clusters are gone when `--prune-missing` is supplied.
   - [x] 1.3 Provide dry-run/verbose flags and structured summary output for downstream tooling/tests.

2. **Drift Helper Enhancements**
   - [x] 2.1 Refactor `db_verify.sh` / `test_data_consistency.sh` so they return machine-readable codes (or drop files) consumed by the reconciler.
   - [x] 2.2 Ensure these helpers can distinguish “cluster missing”, “state mismatch”, and “ok”.

3. **Regression & Workflow Integration**
   - [x] 3.1 Update `tests/regression_test.sh` to run reconciliation immediately after `clean.sh` + `bootstrap.sh`, guaranteeing ≥3 kind and ≥3 k3d clusters.
   - [x] 3.2 Capture reconciliation logs in `/tmp/kindler_reconcile.log` and append a summary + status to `docs/TEST_REPORT.md` / smoke entries.
   - [x] 3.3 Add validation that the mandated cluster counts are met before continuing with the rest of the regression.

4. **Documentation & Guidance**
   - [x] 4.1 Refresh README/README_CN/AGENTS/TESTING docs to describe the declarative workflow (clean → bootstrap → reconcile → validate) and new CLI flags.
   - [x] 4.2 Add troubleshooting guidance for pruning stale DB rows or recreating missing clusters using the reconciler.

5. **Validation**
   - [x] 5.1 Run `scripts/reconcile.sh --dry-run` and `--prune-missing` against a controlled drift scenario to ensure expected actions/logging.
   - [x] 5.2 Execute the full regression pipeline and confirm it passes without manual cluster creation, recording logs in `docs/TEST_REPORT.md`.
