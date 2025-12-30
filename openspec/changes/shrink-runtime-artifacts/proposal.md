## Why
- 当前仓库中仍存在少量“运行时/实验产物”类型的文件直接纳入版本控制，例如 WebUI 后端的 `*.phase2-attempt` 实验实现、`tests/services_test.sh.broken` 等，这些文件既不再被调用，也容易误导新贡献者。
- `config/git.env` 目前包含真实格式的访问凭据，既违背“禁止提交密钥、仅提交 *.example 模板”的约束，也让仓库看起来更像是“某一台环境的快照”而不是可移植的模板。
- OpenSpec 已通过 `tooling-scripts` 规格和 `shrink-file-inventory-tree` 等变更约束了文件清单与脚本收缩，但对“运行时产物/实验残留/敏感配置”的具体处理尚不够细化，导致这类文件在仓库中偶尔“漏网”。

## What Changes
1. 在 `tooling-scripts` 规格中补充“运行时/敏感产物收缩”相关要求：
   - 明确运行时代码中出现的实验实现文件（如 `*.phase2-attempt`）不得长期驻留版本库；若确需保留设计思路，应迁移到文档或 history 目录，而不是与实际实现并列。
   - 明确含真实凭据或近似真实凭据的配置文件不得直接提交（例如 `config/git.env`），只允许提交 `*.example` 模板，并约定脚本优先从未提交的本地文件或环境变量读取。
2. 新建变更 `shrink-runtime-artifacts` 的实施任务：
   - 删除 `webui/backend/app/api/clusters.py.phase2-attempt` 和 `webui/backend/app/services/db_service.py.phase2-attempt`，更新 `FILE_INVENTORY_ALL.md` 以维持严格白名单；若后续需要这些思路，转而在现有 WebUI 文档中记录。
   - 处理 `config/git.env`：从版本库移除当前含凭据的文件，仅保留/强化 `config/git.env.example`，并在文档中强调“本地复制并填充”的流程。
   - 评估并处理明显标记为 `broken` 或不再维护的测试脚本（如 `tests/services_test.sh.broken`），按“修复并纳入流程 / 迁移到 docs/history / 删除”的策略执行，避免持续占用测试目录层级。

## Impact
- 对 WebUI 而言：删除 `*.phase2-attempt` 文件不会改变实际 API 行为，因为当前实现和测试已经全部指向无后缀版本；只会降低误导性和认知成本。
- 对 config 而言：移除 `config/git.env` 的版本控制条目并不会影响脚本功能，只要用户按示例复制生成本地配置即可；安全性和可移植性则显著提升。
- 对 tests 而言：对显式 `broken` 的脚本做出明确处理，将提高测试目录的信噪比；同时保持 `tests/run_tests.sh`、`scripts/regression.sh` 等 canonical 入口不受影响。
- 该变更不会引入新的运行时依赖，仅通过调整文件布局与示例配置，让“最小可用基准”更干净、更易维护。
