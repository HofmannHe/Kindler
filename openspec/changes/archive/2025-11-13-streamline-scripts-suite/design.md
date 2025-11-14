# Design: Streamline Scripts Suite

## Architecture Summary
The change keeps the existing Bash-based tooling surface but enforces a metadata contract so we can automatically inventory supported scripts. New automation (`scripts/scripts_inventory.sh`) will scan top-level `scripts/*.sh` entrypoints, parse canonical headers, and emit Markdown/JSON summaries. Deprecated wrappers and the PostgreSQL helper are removed to eliminate duplicate entrypoints.

## Key Decisions
1. **Metadata Schema**
   - Required keys: `Description`, `Usage`, `Category`, `Status`.
   - Optional key: `See also` (comma-separated list).
   - Each appears near the top of every script as `# Key: value` to keep parsing simple.
   - `Status` vocabulary: `stable`, `experimental`, `deprecated`.

2. **Inventory Tooling**
   - `scripts/scripts_inventory.sh` iterates over `scripts/*.sh` (excluding README/new tool itself when needed), extracts metadata via `awk`, and outputs either Markdown (`--markdown`) or JSON (`--json`).
   - `--check` mode compares existing `docs/scripts_inventory.md` with regenerated output and fails if they differ or metadata is missing.
   - Generation writes grouped tables per `Category` plus a consolidated status summary.

3. **Wrapper Removal**
   - Delete `basic-test.sh`, `monitor_test.sh`, `start_env.sh`, `stop_env.sh`, and `list_env.sh` entirely. Canonical replacements (`smoke.sh`, `cluster.sh start|stop|list`) remain documented.
   - Update `scripts/README.md`, `README.md`, and `README_CN.md` to drop references to removed wrappers.

4. **Single DB Helper**
   - Remove `scripts/lib_db.sh`.
   - Update tests (`tests/db_operations_test.sh`, `tests/webui_comprehensive_test.sh`, `tests/cleanup_test_clusters.sh`) and docs to source `scripts/lib/lib_sqlite.sh`.

5. **Documentation**
   - Regenerate `docs/scripts_inventory.md` via the new tooling.
   - Add a short `docs/scripts_inventory.md` introduction describing categories and statuses.

## Alternatives Considered
- **Keep wrappers but mark deprecated:** Rejected because user request mandates “大幅精简” and wrappers create maintenance overhead.
- **Use JSON/YAML manifests instead of parsing headers:** Rejected to minimize churn; header comments already exist and are easiest to parse.
- **Integrate inventory into a Python tool:** Rejected to avoid new dependencies. Bash + `awk` suffices.

## Testing Strategy
- Unit-like: run `scripts/scripts_inventory.sh --markdown` and `--check` locally.
- Regression: execute `tests/regression_test.sh` (or updated harness) to satisfy clean→bootstrap→create→smoke/test acceptance. Capture logs.
- Static: `shellcheck`/`shfmt` on modified scripts; `rg 'lib_db'` ensures no active references remain.
