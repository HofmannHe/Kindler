## Why
The `scripts/` folder has grown organically and now contains overlapping utilities, legacy variants, and backups. This increases cognitive load and makes it harder to use the correct entrypoints. We need a minimal, non-breaking cleanup to improve readability and discoverability.

## What Changes
- Add a single `scripts/README.md` that categorizes entrypoints vs. libraries, documents usage, and maps deprecated scripts to canonical ones.
- Add deprecation wrappers/notices for legacy helpers that overlap with canonical commands (no behavior change).
- Remove stale backup files with no references.
- Add top-of-file headers to key scripts (description, usage, see-also) for quick orientation.
- Move libraries to `scripts/lib/` and update all sources (`lib.sh`, `lib_sqlite.sh`, `lib_git.sh`, `lib_config.sh`).
- Extend `cluster.sh` to include `start|stop|list` and deprecate `start_env.sh`, `stop_env.sh`, `list_env.sh` via wrappers.
- Fold `portainer_add_local.sh` into `portainer.sh add-local` with a thin wrapper.
- Move `traefik.sh` to `scripts/lib/traefik.sh` and adjust `create_env.sh` to call the new path.

### This Batch (Docs & Cleanup)
- Update `README.md` and `README_CN.md` Stop/Start examples to use `cluster.sh start/stop`.
- Update internal references from `list_env.sh` to `cluster.sh list` where applicable.
- Switch `bootstrap.sh` to call `portainer.sh add-local` directly.
- Remove first batch deprecated wrappers: `haproxy_render.sh`, `portainer_add_local.sh` (after docs updated).

### Additional Consolidation (Physical count reduction)
- Move test scripts to `tests/` and update references.
- Move PostgreSQL helper examples to `examples/postgres/`.
- Move Git helpers to `tools/git/` and update call sites in `create_env.sh`, `delete_env.sh`, `bootstrap.sh`, `check_consistency.sh`.
- Move maintenance utilities to `tools/maintenance/` and update docs/messages.
- Move host dev server to `tools/dev/host_api_server.py` and update architecture docs.
- Move deprecated predefined batch creator and legacy edge scripts to `tools/legacy/`.

## Impact
- Affected scripts: `haproxy_project_route.sh`, `basic-test.sh`, `monitor_test.sh`, `register_edge_agent.sh.backup*`, `start_env.sh`, `stop_env.sh`, `list_env.sh`, `portainer_add_local.sh`, and library paths.
- Canonical entrypoints retained or consolidated: `cluster.sh` (create/delete/import/status/start/stop/list), `create_env.sh`, `delete_env.sh`, `haproxy_route.sh`, `haproxy_sync.sh`, `portainer.sh`, `argocd_register.sh`, `clean.sh`, `smoke.sh`.
- No breaking changes expected; wrappers are provided for deprecated commands and paths updated in-tree.
