Scripts Overview / 脚本总览

This folder contains operational entrypoints and small libraries for the local DevOps environment: Portainer CE as control plane, HAProxy as ingress, and k3d/kind business clusters. The focus is simple, fast, and “just enough.”

Conventions / 约定
- Shebang + `set -Eeuo pipefail` + `IFS=$'\n\t'`
- Keep behavior idempotent; prefer fast-fail, clear logs
- Use `lib/lib.sh` for helpers and `lib/lib_sqlite.sh` for the single source of truth
- Avoid breaking changes; add thin wrappers with deprecation notices when consolidating

Primary Entrypoints / 主要入口脚本
- `bootstrap.sh` — Bring up base infra (HAProxy, Portainer, WebUI, ArgoCD)
- `cluster.sh` — Cluster dispatcher: `create|delete|import|status|start|stop|list`
  Examples: `scripts/cluster.sh create dev`, `scripts/cluster.sh start dev`, `scripts/cluster.sh list`
- `create_env.sh` — Create a business cluster (kind|k3d) and register:
  Usage: `scripts/create_env.sh -n <env> [-p kind|k3d] [--haproxy-route|--no-haproxy-route] [--register-portainer|--no-register-portainer] [--register-argocd|--no-register-argocd]`
- `delete_env.sh` — Delete a cluster and clean registrations
- `haproxy_route.sh` — Add/remove domain routes per environment
- `haproxy_sync.sh` — Reconcile all routes from DB/CSV; `--prune` removes stale
- `portainer.sh` — Portainer lifecycle and API helpers (login, add/del endpoints, add-local)
- `argocd_register.sh` — Register/unregister clusters to ArgoCD (kubectl-based)
- `clean.sh` — Clean all business clusters (preserves devops by default)
- `clean_ns.sh` — Namespace-scoped cleanup for worktrees (development only)
- `smoke.sh` — Minimal validation and append report to `docs/TEST_REPORT.md`

Batch Utilities / 批处理工具
- `batch_create_envs.sh` — moved to `tools/maintenance/batch_create_envs.sh`
- `create_predefined_clusters.sh` — moved to tools/legacy/ (Deprecated). Prefer `tools/maintenance/batch_create_envs.sh`.

Registration / 注册
- `register_edge_agent.sh` — Canonical Edge Agent registration (Portainer) using HAProxy as ingress, with K8s secret for creds
- Deprecated: `batch_edge_register.sh`, `auto_edge_register.sh`, `register_portainer_agents.sh` → use `register_edge_agent.sh`

HAProxy / 路由
- `haproxy_route.sh` — Canonical; environment-level pattern: `<service>.<env>.<BASE_DOMAIN>`
- `haproxy_project_route.sh` — Deprecated (project-level domain). Works but prefer environment-level routing via `haproxy_route.sh`

Libraries / 库
- `lib/lib.sh` — Common helpers (naming, CSV lookup, image preload, waiters)
- `lib/lib_sqlite.sh` — SQLite DB access; provides `db_*` compatible aliases
- `lib/lib_config.sh` — Parse/validate `.kindler.yaml` (optional tooling)
- `lib/lib_git.sh` — Git helpers for branches/repo wiring
- `lib/traefik.sh` — Traefik install/update helper (CLI-style)

Removed This Phase / 本阶段移除
- `portainer_add_local.sh` → use `portainer.sh add-local`
- `haproxy_render.sh` → use `haproxy_sync.sh`（统一由 DB/CSV 驱动，含 ACL/USE_BACKEND/BACKENDS）
- `fix_applicationset.sh` → use `tools/fix_applicationset.sh`
- `fix_git_branches.sh` → use `tools/fix_git_branches.sh`
- `fix_helm_duplicate_resources.sh` → use `tools/fix_helm_duplicate_resources.sh`
- `fix_ingress_controllers.sh` → use `tools/fix_ingress_controllers.sh`
- `fix_haproxy_routes.sh` → use `tools/fix_haproxy_routes.sh`
- `debug_portainer.sh` → use `tools/debug_portainer.sh`
- `registry.sh` → use `tools/registry.sh`
- `reconfigure_host.sh` → use `tools/reconfigure_host.sh`
- `argocd_project.sh` → use `tools/argocd_project.sh`
- `project_manage.sh` → use `tools/project_manage.sh`
- `start_reconciler.sh` → use `tools/start_reconciler.sh`

Deprecated Wrappers / 弃用包装（仍保留以兼容）
- `basic-test.sh` → `smoke.sh`
- `monitor_test.sh` → `smoke.sh`
- `create_predefined_clusters.sh` → `tools/maintenance/batch_create_envs.sh`
- `haproxy_project_route.sh` → `haproxy_route.sh` (environment-level)
- `batch_edge_register.sh`, `auto_edge_register.sh`, `register_portainer_agents.sh` → `register_edge_agent.sh`
- `start_env.sh` → `cluster.sh start <env>`
- `stop_env.sh` → `cluster.sh stop <env>`
- `list_env.sh` → `cluster.sh list`

Moved to tools/（保留 scripts/ 轻量包装）
- 修复/调试类：`fix_applicationset.sh`、`fix_git_branches.sh`、`fix_helm_duplicate_resources.sh`、`fix_ingress_controllers.sh`、`fix_haproxy_routes.sh`
- 实用工具：`debug_portainer.sh`、`registry.sh`、`reconfigure_host.sh`、`argocd_project.sh`、`project_manage.sh`、`start_reconciler.sh`
 - 维护类：`cleanup_orphaned_branches.sh`、`cleanup_orphaned_clusters.sh`（tools/maintenance/）
 - 旧流程：`auto_edge_register.sh`、`batch_edge_register.sh`、`register_portainer_agents.sh`、`complete_edge_registration.sh`（tools/legacy/）

Moved to tests/
- `e2e_test.sh`、`regression_test.sh`、`run_full_test.sh`、`full_cycle.sh`、`full_regression.sh`、`test_*.sh`、`watch_test.sh`、`quick_verify.sh`、`validate_cluster.sh`、`verify_cluster.sh`

Moved to examples/postgres/
- `deploy_postgresql*.sh`、`setup_postgresql_nodeport.sh`、`setup_haproxy_postgres.sh`

Notes / 说明
- Do not deploy whoami to the devops cluster; deploy to business clusters only.
- Do not hardcode environment names; honor CSV/DB and `KINDLER_NS` for isolation.
- GitOps compliance: only ArgoCD manages applications; script deployments are for infra/bootstrap only.

Git utilities moved to tools/git/
- `create_git_branch.sh`, `delete_git_branch.sh`, `init_git_business_branches.sh`, `init_git_devops.sh`, `init_env_branch.sh`, `sync_git_from_db.sh`
