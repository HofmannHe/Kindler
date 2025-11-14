# Proposal: Refactor Scripts Pruning

## Summary
- Build a canonical inventory for everything under `scripts/` so we know the purpose, owner, dependencies, and lifecycle status of each entrypoint.
- Retire wrapper scripts and PostgreSQL-era helpers that duplicate canonical commands yet still occupy surface area.
- Introduce a regression harness that executes the clean → bootstrap → multi-env create → smoke/tests pipeline in one place.
- Keep documentation/tests consistent with the streamlined script set and gate changes via full regression.

## Current Pain & Evidence
1. **No authoritative inventory:** The repo only has prose in `scripts/README.md`, which drifts from reality (e.g., wrappers still listed as “deprecated” but remain callable). There is no machine-readable overview for tooling or docs automation, making it difficult to audit changes before touching infra-critical scripts.
2. **Wrapper scripts never removed:** `scripts/start_env.sh`, `scripts/stop_env.sh`, `scripts/list_env.sh`, `scripts/basic-test.sh`, and `scripts/monitor_test.sh` still exist even though documentation already tells users to prefer `cluster.sh`/`smoke.sh`. These wrappers print deprecation warnings but still carry tests/docs debt and confuse new operators.
3. **Legacy PostgreSQL helper lingers:** `scripts/lib_db.sh` still shells into a Postgres instance even though SQLite (`scripts/lib/lib_sqlite.sh`) is the sole data source. Several tests (`tests/db_operations_test.sh`, `tests/webui_comprehensive_test.sh`) still source the legacy file, so we keep two incompatible code paths alive.
4. **Regression workflow is tribal knowledge:** Acceptance criteria require running clean → bootstrap → create ≥3 kind/k3d envs → validate via Portainer/HAProxy, but there is no single script orchestrating that journey. Recent reports (`full_regression_final.log`, `REGRESSION_FINAL_SUCCESS_REPORT.md`) are hand-written, not reproducible.

## Goals
- **Inventory automation:** Every script exposes standardized metadata (description, category, status, dependencies). `scripts/scripts_inventory.sh` renders both Markdown (`docs/scripts_inventory.md`) and JSON for tooling.
- **Surface reduction:** Only canonical entrypoints remain in `scripts/`. Deprecated wrappers move to `tools/legacy/` (if absolutely required) or are removed entirely after documentation updates.
- **Single data layer:** Remove `scripts/lib_db.sh` and migrate any remaining references/tests to `lib/lib_sqlite.sh`, ensuring SQLite is the only supported backend.
- **Regression harness:** Deliver `scripts/regression.sh` (or equivalent) that runs the mandated clean/bootstrap/create/test workflow, captures logs per phase, and appends the latest run summary to `docs/TEST_REPORT.md`.

## Non-Goals
- Changing cluster creation semantics or HAProxy/Portainer behavior beyond what is necessary to keep the regression harness green.
- Altering the WebUI/API surface (only leverage existing scripts).
- Replacing bats/unit tests with another framework.

## Success Criteria
- Inventory script detects missing metadata and fails CI locally when a new script lacks headers.
- Running `scripts/scripts_inventory.sh --markdown` regenerates `docs/scripts_inventory.md` deterministically.
- Deprecated wrappers and `lib_db.sh` are absent; attempting to execute them fails immediately because the files no longer exist and READMEs point to canonical alternatives.
- `scripts/regression.sh --full` completes clean→bootstrap→create environments (≥3 kind + ≥3 k3d)→smoke/test steps without manual coordination, producing a timestamped log artifact.

## Risks & Mitigations
- **Regressions while pruning:** We will retain a dry-run/preview mode in the inventory + removal scripts to list what will be deleted before enforcing it.
- **Long regression runtime:** The harness will support `--subset` to exercise a smaller matrix locally while CI/nightly uses `--full`.
- **Documentation drift:** Inventory generation doubles as documentation; failures in CI when metadata is incomplete will force docs to stay current.

## Open Questions
1. Should the regression harness push artifacts somewhere besides `docs/TEST_REPORT.md`? (Default to local file unless guidance changes.)
2. Are there external consumers of the deprecated wrappers (automation jobs)? Need confirmation before hard removal—default assumption is “no” because docs already require canonical commands.
