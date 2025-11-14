## MODIFIED Requirements

### Requirement: Script Discoverability
Documentation for scripts SHALL be generated from machine-readable metadata headers.
#### Scenario: Inventory generation is authoritative
- **WHEN** `scripts/scripts_inventory.sh --markdown` runs
- **THEN** it parses metadata headers (Description/Usage/Category/Status) from every maintained script under `scripts/`
- AND regenerates `docs/scripts_inventory.md` with categorized tables
- AND exits non-zero when a script is missing metadata or docs are stale

## ADDED Requirements

### Requirement: Remove deprecated wrappers (batch 3)
Deprecated wrappers SHALL be removed and only referenced in migration notes.

#### Scenario: Wrapper not found (batch 3)
- **WHEN** a user tries to execute `scripts/basic-test.sh`, `scripts/monitor_test.sh`, `scripts/start_env.sh`, `scripts/stop_env.sh`, or `scripts/list_env.sh`
- **THEN** the files are absent
- AND documentation points to `scripts/smoke.sh` and `scripts/cluster.sh` for the same workflows
- AND automation needing old names can only rely on the alias mechanism inside `scripts/cluster.sh`

### Requirement: Single database helper (SQLite only)
All scripts and tests SHALL depend on `scripts/lib/lib_sqlite.sh` as the only database helper.

#### Scenario: No lib_db.sh
- **WHEN** a developer searches for `scripts/lib_db.sh`
- **THEN** the file does not exist
- AND functions such as `db_insert_cluster`, `db_list_clusters`, and `db_next_available_port` are provided by the SQLite helper
- AND tests referencing database helpers source the SQLite library exclusively

### Requirement: Regression harness
There SHALL be a scripted way to execute the mandated clean → bootstrap → create clusters → reconcile → smoke/tests pipeline with logging.

#### Scenario: Run full regression
- **WHEN** `scripts/regression.sh --full` executes
- **THEN** it performs `scripts/clean.sh`, `scripts/bootstrap.sh`, creates every environment defined in `config/environments.csv` (enforcing ≥3 kind and ≥3 k3d)
- AND runs `scripts/reconcile.sh`, `scripts/smoke.sh <env>` for each environment, and `bats tests`
- AND writes logs per phase plus an appended entry in `docs/TEST_REPORT.md`
