## 1. Documentation
- [x] 1.1 Add `scripts/README.md` with entrypoints, libraries, and deprecation mapping
- [x] 1.2 Add brief headers (Description/Usage/See-also) to key scripts
- [x] 1.3 Update `README.md` and `README_CN.md` key commands (add `cluster.sh`), reflect library relocation to `scripts/lib/`
- [x] 1.4 Replace Stop/Start examples to `cluster.sh start/stop` in both READMEs

## 2. Deprecations (Non-breaking)
- [x] 2.1 Mark `haproxy_project_route.sh` as DEPRECATED; keep current behavior and add notice to prefer `haproxy_route.sh`
- [x] 2.2 Make `basic-test.sh` and `monitor_test.sh` thin wrappers invoking `smoke.sh`
- [x] 2.3 Remove stale duplicates: `register_edge_agent.sh.backup`, `register_edge_agent.sh.backup2`
- [x] 2.4 Provide wrappers: `start_env.sh` → `cluster.sh start`, `stop_env.sh` → `cluster.sh stop`, `list_env.sh` → `cluster.sh list`
- [x] 2.5 Fold `portainer_add_local.sh` into `portainer.sh add-local` and wrap

## 2.1 Phase-out (Batch Removals)
- [x] 2.1.1 Update docs to prefer canonical commands (cluster.sh, portainer.sh add-local, haproxy_sync.sh)
- [x] 2.1.2 Update internal references from `list_env.sh` to `cluster.sh list`
- [x] 2.1.3 Switch `bootstrap.sh` to use `portainer.sh add-local`
- [x] 2.1.4 Remove deprecated wrappers: `haproxy_render.sh`, `portainer_add_local.sh`

## 3. Physical Layout Reduction
- [x] 3.1 Move tests to `tests/` (e2e/regression/full_cycle/test_*.sh/watch_test/quick_verify/validate/verify)
- [x] 3.2 Move PostgreSQL examples to `examples/postgres/` (deploy/setup*)
- [x] 3.3 Move maintenance scripts to `tools/maintenance/` (cleanup_orphaned_*.sh)
- [x] 3.4 Move Git utilities to `tools/git/` (create/delete/init*/sync_git_from_db.sh)
- [x] 3.5 Move Host API server to `tools/dev/host_api_server.py`
- [x] 3.6 Move legacy helpers to `tools/legacy/` (create_predefined_clusters.sh, edge agent legacy)

## 3. Consolidation
- [x] 3.1 Move libraries to `scripts/lib/`: `lib.sh`, `lib_sqlite.sh`, `lib_git.sh`, `lib_config.sh`
- [x] 3.2 Update all script and test sources to `scripts/lib/*.sh`
- [x] 3.3 Extend `cluster.sh` with `start|stop|list` subcommands (integrate prior scripts)
- [x] 3.4 Move `traefik.sh` to `scripts/lib/traefik.sh` and update `create_env.sh`
- [x] 3.5 Deprecate `haproxy_render.sh` in favor of `haproxy_sync.sh`
- [x] 3.6 Relocate selected fix/debug utilities to `tools/` with wrappers: `debug_portainer.sh`, `registry.sh`, `reconfigure_host.sh`, `fix_haproxy_routes.sh`

## 4. Validation
- [ ] 4.1 Shellcheck and shfmt formatting for changed files
- [ ] 4.2 Smoke path: `scripts/clean.sh` → `scripts/bootstrap.sh` → `scripts/cluster.sh create ...` (≥3 kind, ≥3 k3d) → `scripts/haproxy_sync.sh` → `scripts/smoke.sh <env>`
- [ ] 4.3 Verify wrappers print notices and exit codes propagate
