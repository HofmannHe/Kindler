# Tasks: Streamline Scripts Suite

1. **Standardize metadata**
   - [x] 1.1 Add `Description`, `Usage`, `Category`, `Status`, and optional `See also` headers to every maintained script under `scripts/*.sh`.
   - [x] 1.2 Document the schema inside `scripts/scripts_inventory.sh` and add shellcheck/shfmt coverage.

2. **Inventory automation**
   - [x] 2.1 Implement `scripts/scripts_inventory.sh` with `--markdown`, `--json`, and `--check` flags; fail when metadata is missing or docs stale.
   - [x] 2.2 Auto-generate `docs/scripts_inventory.md` grouped by category/status using the new tool and commit the refreshed file.

3. **Prune duplicates**
   - [x] 3.1 Remove deprecated wrappers (`basic-test.sh`, `monitor_test.sh`, `start_env.sh`, `stop_env.sh`, `list_env.sh`) and scrub references from READMEs.
   - [x] 3.2 Delete `scripts/lib_db.sh`; update tests/docs to source `scripts/lib/lib_sqlite.sh` exclusively; run `rg 'lib_db'` to ensure no active references remain.

4. **Validation**
   - [x] 4.1 Run `scripts/scripts_inventory.sh --check` to confirm metadata/doc sync.
   - [x] 4.2 Execute the full regression pipeline (clean → bootstrap → create ≥3 kind + ≥3 k3d envs via `scripts/create_env.sh` → smoke/tests) and capture logs or justify if infrastructure unavailable.
