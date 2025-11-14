# Tasks: Reinforce Declarative Operations

1. **Scheduling Wrapper & Logging**
  - [x] 1.1 Add `scripts/reconcile_loop.sh` (or equivalent) supporting `--interval`, `--once`, `--max-runs`, and `--prune-missing` passthrough.
  - [x] 1.2 Append every reconcile run (loop or direct) to `logs/reconcile_history.jsonl` with timestamp, exit code, cluster summary, and invoke source.
  - [x] 1.3 Expose a CLI (`scripts/reconcile.sh --last-run` or helper script) to print the latest summary for docs/tests; update regression harness to include it in `docs/TEST_REPORT.md`.

2. **Lifecycle Verification & State Source**
  - [x] 2.1 Make `create_env.sh` and `delete_env.sh` run `scripts/db_verify.sh --json-summary` on success (unless `SKIP_DB_VERIFY=1`), failing fast when drift persists.
  - [x] 2.2 Emit WARN whenever CSV defaults are used post-bootstrap, steering contributors back to SQLite as the authoritative source.

3. **Subsystem Reliability**
  - [x] 3.1 Add retry/backoff (with bounded attempts) to Portainer endpoint CRUD, ArgoCD registration, and Git branch helpers; bubble non-zero exit codes to callers.
  - [x] 3.2 Ensure `scripts/reconcile.sh` stops when these sub-steps fail and surfaces actionable error messages.

4. **Documentation & Samples**
  - [x] 4.1 Update README/README_CN/AGENTS/TESTING docs to describe the automation loop, logging locations, and verification expectations.
  - [x] 4.2 Provide cron/systemd examples plus guidance on pruning `logs/reconcile_history.jsonl`.

5. **Validation**
  - [x] 5.1 Run the reconcile loop in `--once` mode within regression to confirm history logging and DB verification hooks.
  - [x] 5.2 Capture the new log snippet in `docs/TEST_REPORT.md` and ensure scripts/tests cover failure and retry paths.
