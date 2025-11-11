## MODIFIED Requirements

### Requirement: Script Discoverability
The project SHALL provide clear documentation for scripts and their intended usage.

#### Scenario: Scripts overview
- WHEN a developer opens `scripts/README.md`
- THEN they see categorized entrypoints and libraries
- AND a mapping of deprecated scripts to canonical replacements
- AND usage examples for the primary commands

### Requirement: Non-breaking Deprecation
Deprecated scripts SHALL continue to work while guiding users to canonical commands until explicitly removed in a documented phase-out.

#### Scenario: Run deprecated wrapper
- GIVEN `basic-test.sh` exists as a wrapper
- WHEN the script runs
- THEN it prints a deprecation notice pointing to `smoke.sh`
- AND it forwards args and exit code to the canonical command

## ADDED Requirements

### Requirement: Script Headers
Key scripts SHALL include a short header (Description/Usage/See-also) to reduce time-to-understand.
 
#### Scenario: Open a key script
- WHEN a developer opens `create_env.sh` or `haproxy_route.sh`
- THEN the header describes purpose, synopsis, and related commands

### Requirement: Canonical Lifecycle Commands
Documentation and examples SHALL prefer `scripts/cluster.sh start|stop|list` over legacy wrappers (`start_env.sh`, `stop_env.sh`, `list_env.sh`).

#### Scenario: Stop/Start example in README
- WHEN a user reads the Stop/Start examples in `README.md` and `README_CN.md`
- THEN the commands use `scripts/cluster.sh stop <env>` and `scripts/cluster.sh start <env>`
- AND no new examples recommend the legacy wrappers

## REMOVED Requirements

### Requirement: Remove deprecated wrappers (batch 1)
The following deprecated wrappers MUST be removed after documentation updates:
- `scripts/haproxy_render.sh` → use `scripts/haproxy_sync.sh`
- `scripts/portainer_add_local.sh` → use `scripts/portainer.sh add-local`

#### Scenario: Wrapper not found
- WHEN a user tries to run `scripts/portainer_add_local.sh` or `scripts/haproxy_render.sh` after this change
- THEN the files are absent
- AND the canonical replacements are documented in `README.md` and `scripts/README.md`

### Requirement: Remove deprecated wrappers (batch 2)
The following deprecated wrappers MUST be removed after documentation updates and internal references are migrated:
- `scripts/fix_applicationset.sh` → `tools/fix_applicationset.sh`
- `scripts/fix_git_branches.sh` → `tools/fix_git_branches.sh`
- `scripts/fix_helm_duplicate_resources.sh` → `tools/fix_helm_duplicate_resources.sh`
- `scripts/fix_ingress_controllers.sh` → `tools/fix_ingress_controllers.sh`
- `scripts/fix_haproxy_routes.sh` → `tools/fix_haproxy_routes.sh`
- `scripts/debug_portainer.sh` → `tools/debug_portainer.sh`
- `scripts/registry.sh` → `tools/registry.sh`
- `scripts/reconfigure_host.sh` → `tools/reconfigure_host.sh`
- `scripts/argocd_project.sh` → `tools/argocd_project.sh`
- `scripts/project_manage.sh` → `tools/project_manage.sh`
- `scripts/start_reconciler.sh` → `tools/start_reconciler.sh`

#### Scenario: Tool wrapper not found
- WHEN a user tries to run any of the above removed wrappers
- THEN the files are absent in `scripts/`
- AND the tools exist under `tools/` with equivalent functionality
- AND READMEs point to the `tools/` paths
