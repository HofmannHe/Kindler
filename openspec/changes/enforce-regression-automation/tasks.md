1. - [x] 梳理回归脚本现状：确认 `tests/regression_test.sh` 的真实步骤、缺失的 CLI 选项，以及日志/清理策略。
2. - [x] 撰写《docs/REGRESSION_TEST_PLAN.md》（或更新现有文档）描述“纯脚本回归计划”，覆盖 clean → bootstrap → reconcile → smoke/bats → 数据一致性 → 清理/test-report。
3. - [x] 新增 `scripts/regression.sh` 入口并扩展 `tests/regression_test.sh`：支持文档声明的参数、执行 smoke/bats、自动清理测试集群。
4. - [x] 运行 `scripts/regression.sh --full`（或 `tests/regression_test.sh` 等效模式），若失败则修复脚本/配置直到通过，并将最新 `Reconcile Snapshot + 测试结果` 追加到 `docs/TEST_REPORT.md`。
5. - [x] 更新 `tooling-scripts` spec，确保“脚本化回归计划 + `scripts/regression.sh --full`”被正式约束，并通过 `openspec validate enforce-regression-automation --strict`。
