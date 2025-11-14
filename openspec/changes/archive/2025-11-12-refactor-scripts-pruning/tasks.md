# Tasks: Refactor Scripts Pruning

1. - [ ] Add standardized metadata headers to every maintained script under `scripts/` (excluding `lib/`), fail inventory generation when metadata is missing.
2. - [ ] Implement `scripts/scripts_inventory.sh` that parses metadata and outputs Markdown/JSON plus `--check` mode; regenerate `docs/scripts_inventory.md` from it.
3. - [ ] Update `scripts/README.md`, `README.md`, and `README_CN.md` to explain the new inventory source and script categories.
4. - [ ] Remove deprecated wrappers (`basic-test.sh`, `monitor_test.sh`, `start_env.sh`, `stop_env.sh`, `list_env.sh`) and provide transition notes; ensure `cluster.sh` offers optional alias handling for automation.
5. - [ ] Delete `scripts/lib_db.sh`, move any remaining functions/tests/docs to `scripts/lib/lib_sqlite.sh`, and update tests to source the SQLite library only.
6. - [ ] Introduce `scripts/regression.sh` orchestrating clean → bootstrap → create ≥3 kind & ≥3 k3d envs → reconcile → smoke/tests with logging and `--subset`/`--dry-run` flags.
7. - [ ] Extend bats/automation tests to cover the inventory script and regression harness argument parsing; update `docs/TEST_REPORT.md` format expectations if needed.
8. - [ ] Run the full regression harness (`scripts/regression.sh --full`) and attach/log the resulting artifacts per acceptance criteria.
