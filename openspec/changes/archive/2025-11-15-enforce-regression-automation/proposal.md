## Why
- 回归测试流程跨越 clean → bootstrap → reconcile → smoke/test 多个脚本，但缺少“禁止手工操作”的统一执行计划，导致不同贡献者仍旧依赖手敲命令。
- `tooling-scripts` 规格要求 `scripts/regression.sh --full` 管道化整个流程，然而仓库当前只有 `tests/regression_test.sh`，文档/脚本的入口与规范脱节，难以追踪验收标准。
- 现有文档（如 `docs/REGRESSION_TEST.md`）仍旧保留 PostgreSQL/手动验证步骤，没有说明如何借助 SQLite + `scripts/reconcile_loop.sh` 自动生成 ≥3 kind / ≥3 k3d 的业务集群，更没有说明如何记录 `docs/TEST_REPORT.md`。

## What Changes
1. 引入一个规范的回归测试计划文档（中文优先），明确“必须通过脚本执行”的步骤、依赖、日志产物与故障排查方法，并将 `tests/regression_test.sh` 标记为唯一入口；文档中写明任何需要人工干预即视为失败。
2. 提供 `scripts/regression.sh` 作为 `tooling-scripts` 规格要求的入口（内部复用 `tests/regression_test.sh`），并扩展回归脚本本身：
   - 支持 `--full/--skip-clean/--skip-bootstrap/--clusters` 等参数，与 `docs/TESTING_GUIDE.md` 示例一致。
   - 在调和成功后自动对所有业务集群执行 `scripts/smoke.sh <env>`，并运行 `bats tests` 确认脚本/库的单元用例。
   - 运行完成后自动清理由脚本创建的 `test-script-*` 集群，确保“零手工收尾”。
3. 在 `tooling-scripts` spec 中新增/更新要求，确保“脚本化回归计划文档 + `scripts/regression.sh --full`”成为验收基线。

## Impact
- 文档：新增回归测试计划（docs/*）、更新 `docs/REGRESSION_TEST.md`/`docs/TESTING_GUIDE.md` 的调用示例。
- 脚本：`tests/regression_test.sh`（参数化 & 扩展步骤）、新增 `scripts/regression.sh` 入口、`docs/TEST_REPORT.md` 持续追加日志。
- 测试：实际运行 `scripts/regression.sh --full`（或等价脚本）并修复出现的问题，提供日志与 `docs/TEST_REPORT.md` 记录。
