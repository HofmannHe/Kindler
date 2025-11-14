# Design: Reinforce Declarative Operations

## Overview
Build on the existing reconciler without introducing a new service. We add a thin scheduling wrapper and richer logging/auditing so operators can keep the system converged with minimal manual effort.

## Components
1. **Reconcile Loop Wrapper**
   - New script (e.g., `scripts/reconcile_loop.sh`) accepts `--interval <minutes>` and `--once`.
   - Each iteration runs `scripts/reconcile.sh --from-db` (and optional `--prune-missing` when requested) and writes summary JSON to `logs/reconcile_history.jsonl`.
   - Supports `--max-runs` for CI, so regression can invoke a single pass via the same wrapper.

2. **Audit Log + CLI**
   - `scripts/reconcile.sh` emits structured JSON via stdout and also appends to the history file.
   - A helper (`scripts/reconcile.sh --last-run` or `scripts/reconcile_audit.sh`) reads the history and prints human-friendly summaries for docs/tests.

3. **Lifecycle Hardening**
   - `create_env.sh` / `delete_env.sh` call `scripts/db_verify.sh --json-summary --strict` immediately after they finish (unless `--skip-verify` is passed for emergencies). Failure stops the pipeline and surfaces drift sooner.
   - CSV fallback paths log WARN (once per invocation) so contributors know SQLite must be authoritative.

4. **Subsystem Retry Policy**
   - Portainer: add retry/backoff when `add-endpoint`, `del-endpoint`, `api-login`, and Edge registration run via scripts.
   - ArgoCD/Git helpers bubble up non-zero exit codes; reconciler aborts with clear error when sub-steps fail repeatedly.

5. **Documentation & Samples**
   - README/README_CN/AGENTS detail how to enable cron/systemd timers pointing at `reconcile_loop.sh --interval 15 --log-dir ...`.
   - Testing guides updated to require attaching the latest reconcile log snippet to `docs/TEST_REPORT.md`.

## Risks & Mitigations
- **Log growth**: JSONL files could grow without bound. Mitigate by documenting log rotation (e.g., `logrotate` snippet) and optionally adding `--max-history` prune flag later.
- **Long-running loop blocking CI**: Provide `--once` and `--max-runs 1` options; regression harness can keep using single-pass mode.
- **Extra verification slowing workflows**: Allow `SKIP_DB_VERIFY=1` env for emergencies but make default strict.
