# Design: Refactor Scripts Pruning

## Overview
We will introduce script metadata automation, remove redundant wrappers, consolidate database helpers, and add a reproducible regression harness. The design leans on existing entrypoints (`cluster.sh`, `create_env.sh`, `haproxy_sync.sh`, `smoke.sh`, `reconcile.sh`) without changing their external contracts.

## 1. Script Metadata & Inventory Generation
- **Metadata schema:** The first comment block of every script under `scripts/` (excluding `lib/`) will carry `# Description:`, `# Usage:`, `# Category:`, `# Status:` lines. `Status` is one of `canonical`, `experimental`, `legacy`.
- **Parser:** A new helper `scripts/scripts_inventory.sh` will parse the headers, validate required keys, and emit either Markdown (`--markdown`) or JSON (`--json`). Missing keys cause a non-zero exit to gate CI.
- **Documentation:** `docs/scripts_inventory.md` will be generated from the Markdown output. It includes per-script tables (purpose, dependencies, replacement if legacy) plus aggregated stats (count per category/status).
- **Automation:** A lightweight check (invoked from `scripts/regression.sh --inventory-check` and future CI) runs `scripts/scripts_inventory.sh --check` to ensure inventory and README stay synchronized.

## 2. Wrapper Retirement
- **Scope:** Remove `scripts/basic-test.sh`, `scripts/monitor_test.sh`, `scripts/start_env.sh`, `scripts/stop_env.sh`, `scripts/list_env.sh`. Each already prints a deprecation warning today.
- **Guidance:** Update `README.md`, `README_CN.md`, and `scripts/README.md` to reference `scripts/cluster.sh` and `scripts/smoke.sh` exclusively. Include a migration table inside `docs/scripts_inventory.md`.
- **Implementation detail:** `scripts/cluster.sh` will gain a `legacy-alias` subcommand (non-advertised) so internal references (if any) can temporarily re-map names during testing without restoring files.

## 3. Database Helper Consolidation
- **Removal:** Delete `scripts/lib_db.sh` and keep SQLite (`scripts/lib/lib_sqlite.sh`) as the single source of truth.
- **Compat shim:** Provide a thin shim within `lib/lib_sqlite.sh` exporting the same function names (`db_query`, `db_insert_cluster`, etc.) so existing callers continue to work without code churn.
- **Tests:** Update `tests/db_operations_test.sh`, `tests/webui_comprehensive_test.sh`, and other references to source the SQLite library. Where Postgres-specific instructions exist in docs (`docs/SQLITE_MIGRATION_*`), append a short historical note and clearly state the file was removed.

## 4. Regression Harness
- **Entrypoint:** New `scripts/regression.sh` orchestrates the acceptance criteria: `clean.sh` → `bootstrap.sh` → create environments for every row in `config/environments.csv` (at least 3 kind + 3 k3d enforced) → `scripts/reconcile.sh` → `scripts/smoke.sh <env>` for each env → `bats tests`.
- **Logging:** Each phase writes to `logs/regression/<timestamp>/phase.log`; an aggregated summary is appended to `docs/TEST_REPORT.md`.
- **Config:** Supports `--full` (default) and `--subset kind|k3d` for faster dev cycles; `--dry-run` prints planned actions without mutating state.

## 5. Testing & Validation Plan
- **Unit-style tests:** Extend existing bats tests (or add new ones) to cover inventory parsing (mock script headers) and regression harness argument parsing.
- **Integration:** Run `scripts/regression.sh --subset kind` in CI (if available) and `--full` before merging, capturing logs for review.
- **Docs verification:** Inventory generation is part of regression, ensuring `docs/scripts_inventory.md` stays aligned after every run.
