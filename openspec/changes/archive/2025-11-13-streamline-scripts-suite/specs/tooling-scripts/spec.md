## MODIFIED Requirements
### Requirement: Script Discoverability
Inventory automation SHALL parse standardized metadata headers from every maintained script.
#### Scenario: Inventory enforces metadata contract
- **WHEN** `scripts/scripts_inventory.sh --markdown` runs
- **THEN** it parses `Description`, `Usage`, `Category`, `Status`, and optional `See also` headers from every `scripts/*.sh` entrypoint
- AND fails with a non-zero exit code if any required key is missing
- AND regenerates `docs/scripts_inventory.md` grouped by category with status counts
- AND `scripts/scripts_inventory.sh --check` fails whenever the checked-in Markdown is stale relative to regenerated output

### Requirement: Remove deprecated wrappers (batch 3)
Deprecated wrappers SHALL be absent from the repository and documentation SHALL point to canonical replacements only.
#### Scenario: Wrapper commands unavailable
- **WHEN** a user runs `ls scripts/basic-test.sh scripts/monitor_test.sh scripts/start_env.sh scripts/stop_env.sh scripts/list_env.sh`
- **THEN** the files do not exist
- AND `docs/scripts_inventory.md`, `scripts/README.md`, `README.md`, and `README_CN.md` mention only `scripts/smoke.sh` and `scripts/cluster.sh` for basic tests/start-stop/list workflows

### Requirement: Single database helper (SQLite only)
All scripts, docs, and tests SHALL source `scripts/lib/lib_sqlite.sh`; the PostgreSQL helper must not exist.
#### Scenario: No lib_db.sh consumers
- **WHEN** a developer searches for `lib_db.sh`
- **THEN** the file is absent under `scripts/`
- AND active docs/tests source `scripts/lib/lib_sqlite.sh`
- AND `scripts/scripts_inventory.sh --check` would fail if a new reference to `lib_db.sh` appears

## ADDED Requirements
### Requirement: Script Audit Report
Script evaluations SHALL be captured in an auto-generated Markdown report for operators.
#### Scenario: Audit report updated
- **WHEN** `docs/scripts_inventory.md` is opened after running `scripts/scripts_inventory.sh --markdown`
- **THEN** it lists each maintained script with columns for Description, Usage, Category, and Status
- AND includes a summary section showing counts per category and status to highlight redundant/unneeded entries during audits
