# Proposal: Enforce Declarative Reconciliation

## Summary
- Treat SQLite as the single source of truth for business clusters by reconciling desired rows with actual k3d/kind resources before every lifecycle/test pipeline.
- Extend the scripts toolchain so drift detection (DB vs clusters vs ApplicationSet vs Portainer/ArgoCD) automatically repairs or purges resources rather than only reporting.
- Update documentation and regression harnesses so the declarative workflow (clean → bootstrap → reconcile → validate) is explicit, automated, and verified end-to-end.

## Motivation
Despite migrating to SQLite and ApplicationSet driven flows, the current toolchain still behaves imperatively:
- `clean.sh --all` wipes clusters but leaves SQLite rows intact; subsequent tests immediately fail because the database references non-existent clusters.
- `test_data_consistency.sh` / `db_verify.sh` only report drift; they do not offer an automated way to converge resources back to the desired state.
- Regression scripts assume clusters exist simply because CSV rows exist, contradicting the declarative promise.

These gaps cost time on every regression and undermine the intent of a fully declarative platform.

## Goals
1. Provide a first-class reconciliation script/command that reads the SQLite `clusters` table and ensures each entry reaches its desired lifecycle state (create missing clusters, delete orphaned resources, update registrations/routes, or prune DB rows for deleted clusters when requested).
2. Integrate reconciliation into regression/smoke workflows so the mandated clean → bootstrap → create (≥3 kind, ≥3 k3d) steps are satisfied automatically from the database, without manual sequencing.
3. Document the declarative workflow in README/AGENTS/TESTING docs so contributors know to run reconcile before/after destructive operations.

## Non-Goals
- Changing the schema of the `clusters` table.
- Replacing ApplicationSet/GitOps flows (only ensure they stay in sync during reconciliation).
- Altering WebUI behavior beyond invoking the shared scripts.

## Success Criteria
- Running the new reconciliation entrypoint after `clean.sh --all` recreates every cluster declared in SQLite (or prunes rows via flag) without manual commands.
- Regression harness runs: clean → bootstrap → reconcile → smoke/tests, and the data consistency step no longer fails due to missing clusters.
- Docs clearly describe the declarative cycle, and scripts expose flags for dry-run vs repair vs prune actions.
