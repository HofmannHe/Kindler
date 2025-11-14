# Scripts Inventory

_Generated via scripts/scripts_inventory.sh_

## Summary
- Total scripts: 22
- Status counts:
  - experimental: 3
  - stable: 19
- Category counts:
  - diagnostics: 5
  - gitops: 4
  - inventory: 1
  - lifecycle: 7
  - registration: 2
  - routing: 2
  - testing: 1

### diagnostics

| Script | Description | Usage | Status | See also |
| --- | --- | --- | --- | --- |
| `scripts/check_consistency.sh` | Compare DB (SQLite), Git branches, and Kubernetes clusters; report drift with fix hints. | `scripts/check_consistency.sh` | stable | scripts/reconcile.sh, scripts/sync_applicationset.sh |
| `scripts/db_verify.sh` | Validate SQLite cluster records against actual Kubernetes contexts and optionally prune stale rows. | `scripts/db_verify.sh [--cleanup-missing] [--json-summary]` | stable | scripts/test_data_consistency.sh, scripts/check_consistency.sh |
| `scripts/smoke.sh` | Minimal validation of HAProxy routes and Portainer endpoints; appends a report to docs/TEST_REPORT.md. | `scripts/smoke.sh <env> [service]` | stable | scripts/haproxy_route.sh, scripts/portainer.sh |
| `scripts/test_data_consistency.sh` | Full data consistency sweep across SQLite, clusters, ApplicationSet, Portainer, and ArgoCD. | `scripts/test_data_consistency.sh [--json-summary]` | stable | scripts/db_verify.sh, scripts/check_consistency.sh |
| `scripts/test_sqlite_migration.sh` | Validate SQLite clusters schema after migration and ensure baseline rows exist. | `scripts/test_sqlite_migration.sh` | stable | scripts/db_verify.sh, scripts/test_data_consistency.sh |

### gitops

| Script | Description | Usage | Status | See also |
| --- | --- | --- | --- | --- |
| `scripts/reconcile_loop.sh` | Thin scheduling wrapper for scripts/reconcile.sh that supports looped execution and history summaries. | `scripts/reconcile_loop.sh [--interval <value>] [--max-runs <n>|--once] [reconcile-flags...]` | experimental | scripts/reconcile.sh, tools/start_reconciler.sh |
| `scripts/reconciler.sh` | Declarative reconciler that reads desired cluster state from SQLite and applies it via scripts. | `scripts/reconciler.sh [once|loop]` | experimental | scripts/reconcile.sh, scripts/create_env.sh, scripts/delete_env.sh |
| `scripts/reconcile.sh` | Declarative reconciliation entrypoint that converges SQLite desired state and final sync steps. | `scripts/reconcile.sh [--from-db] [--dry-run] [--prune-missing]` | stable | scripts/reconciler.sh, scripts/create_env.sh, scripts/delete_env.sh |
| `scripts/sync_applicationset.sh` | Generate ArgoCD ApplicationSet definitions from SQLite and optionally lock during updates. | `scripts/sync_applicationset.sh` | stable | scripts/reconcile.sh, tools/git/sync_git_from_db.sh |

### inventory

| Script | Description | Usage | Status | See also |
| --- | --- | --- | --- | --- |
| `scripts/scripts_inventory.sh` | Generate Markdown/JSON inventory from script metadata and verify docs/scripts_inventory.md is current. | `scripts/scripts_inventory.sh [--markdown|--json] [--output <file>] [--check]` | stable | scripts/README.md, docs/scripts_inventory.md |

### lifecycle

| Script | Description | Usage | Status | See also |
| --- | --- | --- | --- | --- |
| `scripts/bootstrap.sh` | Bring up the base devops stack (HAProxy, Portainer, WebUI, ArgoCD) and prepare shared networks/images. | `scripts/bootstrap.sh` | stable | scripts/clean.sh, scripts/portainer.sh, tools/setup/setup_devops.sh |
| `scripts/clean_ns.sh` | Namespace-scoped cleanup for worktree development; removes only resources tagged by KINDLER_NS. | `KINDLER_NS=<ns> scripts/clean_ns.sh [--from-csv] [env1 ...]` | stable | scripts/clean.sh, scripts/cluster.sh, scripts/haproxy_route.sh |
| `scripts/clean.sh` | Clean business clusters and related infra state; preserve devops unless --all/--include-devops. | `scripts/clean.sh [--all] [--include-devops]` | stable | scripts/bootstrap.sh, scripts/create_env.sh, scripts/clean_ns.sh |
| `scripts/cleanup_nonexistent_clusters.sh` | Remove Portainer endpoints (and optional DB rows) for clusters that no longer exist. | `scripts/cleanup_nonexistent_clusters.sh [--dry-run] [--prune-db]` | experimental | scripts/reconcile.sh, scripts/db_verify.sh, scripts/portainer.sh |
| `scripts/cluster.sh` | Unified dispatcher for cluster lifecycle commands (create/delete/import/status/start/stop/list). | `scripts/cluster.sh <create|delete|import|status|start|stop|list> <env> [args]` | stable | scripts/create_env.sh, scripts/delete_env.sh, scripts/clean.sh |
| `scripts/create_env.sh` | Create a business cluster (kind|k3d), ensure Traefik, add HAProxy route, and register with Portainer/ArgoCD as requested. | `scripts/create_env.sh -n <name> [-p kind|k3d] [--node-port <port>] [--pf-port <port>] \` | stable | scripts/delete_env.sh, scripts/haproxy_route.sh, scripts/argocd_register.sh, scripts/portainer.sh |
| `scripts/delete_env.sh` | Delete a business cluster and clean HAProxy/Portainer/ArgoCD/Git registrations. | `scripts/delete_env.sh -n <name> [-p kind|k3d]` | stable | scripts/create_env.sh, scripts/haproxy_route.sh, scripts/argocd_register.sh, scripts/portainer.sh |

### registration

| Script | Description | Usage | Status | See also |
| --- | --- | --- | --- | --- |
| `scripts/argocd_register.sh` | Register or unregister a cluster with ArgoCD via kubectl (serviceaccount token). | `scripts/argocd_register.sh <register|unregister> <cluster_name> [provider]` | stable | scripts/create_env.sh, scripts/delete_env.sh |
| `scripts/portainer.sh` | Manage Portainer CE (compose up/down) and call simple API helpers (auth, endpoints CRUD). | `scripts/portainer.sh up|down|api-login|add-endpoint|del-endpoint [...]` | stable | tools/setup/register_edge_agent.sh, scripts/create_env.sh |

### routing

| Script | Description | Usage | Status | See also |
| --- | --- | --- | --- | --- |
| `scripts/haproxy_route.sh` | Manage environment-level HAProxy routes (<service>.<env>.<BASE_DOMAIN>) with idempotent add/remove. | `scripts/haproxy_route.sh {add|remove} <env-name> [--node-port <port>]` | stable | scripts/haproxy_sync.sh, scripts/create_env.sh |
| `scripts/haproxy_sync.sh` | Reconcile HAProxy routes from SQLite (preferred) or CSV with optional pruning. | `scripts/haproxy_sync.sh [--prune]` | stable | scripts/haproxy_route.sh |

### testing

| Script | Description | Usage | Status | See also |
| --- | --- | --- | --- | --- |
| `scripts/regression.sh` | Canonical entrypoint for the scripted regression harness (clean → bootstrap → reconcile → smoke/tests). | `scripts/regression.sh [--full|--skip-clean|--skip-bootstrap|--clusters a,b]` | stable | tests/regression_test.sh |

