# Proposal: Streamline Scripts Suite

## Summary
- Build an auditable inventory for every maintained entrypoint in `scripts/` by parsing standardized metadata and regenerating `docs/scripts_inventory.md`.
- Retire redundant wrappers (`basic-test.sh`, `monitor_test.sh`, `start_env.sh`, `stop_env.sh`, `list_env.sh`) and the legacy PostgreSQL helper `scripts/lib_db.sh` so only canonical commands remain.
- Update documentation/tests to source `scripts/lib/lib_sqlite.sh` exclusively and reflect the trimmed surface area.
- Run the mandated clean → bootstrap → multi-environment create → smoke/tests regression to prove the streamlined suite performs as expected.

## Current Pain & Evidence
1. **No trustworthy inventory:** `scripts/README.md` lists canonical commands but wrappers still exist on disk. There is no machine-readable view; `ls scripts` shows 20+ files yet only a subset are documented. Without tooling we cannot prove coverage or status (stable/deprecated).
2. **Wrappers never removed:** Despite earlier deprecation, `scripts/basic-test.sh`, `scripts/monitor_test.sh`, `scripts/start_env.sh`, `scripts/stop_env.sh`, and `scripts/list_env.sh` are still executable entrypoints, keeping extra names alive for operators.
3. **Legacy DB helper still around:** `scripts/lib_db.sh` shells into a PostgreSQL pod even though SQLite is our single source of truth. Tests such as `tests/db_operations_test.sh`, `tests/webui_comprehensive_test.sh`, and `tests/cleanup_test_clusters.sh` still source it, so we maintain incompatible code paths.
4. **Docs/tests drift:** Multiple docs (e.g., `docs/CLUSTER_CONFIG_ARCHITECTURE.md`, `docs/TESTING_GUIDELINES.md`) continue pointing to the removed helper/wrappers, making it unclear which commands to use when onboarding.

## Goals
- **Inventory automation:** Add `scripts/scripts_inventory.sh` that parses metadata headers (Description/Usage/Category/Status/See also) from every curated script and regenerates `docs/scripts_inventory.md` with per-category tables. Missing metadata causes non-zero exit to guard CI/regression.
- **Surface reduction:** Remove deprecated wrappers and ensure `scripts/README.md` plus generated inventory show only canonical commands.
- **Single SQLite path:** Delete `scripts/lib_db.sh`, update docs/tests to source `scripts/lib/lib_sqlite.sh`, and ensure inventory marks the SQLite helper as the only supported database interface.
- **Regression proof:** Execute the full clean → bootstrap → create ≥3 kind + ≥3 k3d environments → smoke/tests flow after refactor, attaching logs/results.

## Non-Goals
- Changing the behavior of canonical scripts beyond metadata headers and doc refresh.
- Reworking Portainer/HAProxy/Kubernetes flows except as necessary for regression to stay green.
- Modifying WebUI code paths (only scripts/docs/tests in scope).

## Success Criteria
- `scripts/scripts_inventory.sh --markdown` regenerates `docs/scripts_inventory.md` deterministically; `--check` fails when docs are stale or metadata missing.
- Running `rg 'lib_db'` finds no references outside of archived docs; active docs/tests all reference `scripts/lib/lib_sqlite.sh`.
- Deprecated wrappers no longer exist; inventory/doc only list canonical commands (`cluster.sh`, `smoke.sh`, etc.).
- Full regression finishes without manual intervention and produces logs proving the streamlined script set functions end-to-end.

## Risks & Mitigations
- **Metadata churn:** Adding headers to every script may conflict with future changes. Mitigate by documenting the schema inside `scripts/scripts_inventory.sh` and validating deterministically.
- **Regression runtime:** Full pipeline can take considerable time. Provide checkpoints/log streaming plus the option to reuse `tests/regression_test.sh` when available.
- **External automation still calling wrappers:** Communicate via docs (inventory + README) that wrappers are gone; maintainers can add aliases inside `cluster.sh` if some automation still needs them.

## Open Questions
1. Should the inventory also cover helper libraries under `scripts/lib/`? Initial scope targets entrypoints only.
2. Is there appetite for JSON output from the inventory for future tooling (defaults to Markdown but CLI can be extended)?
