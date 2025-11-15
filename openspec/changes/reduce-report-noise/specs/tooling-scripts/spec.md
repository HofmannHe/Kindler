## ADDED Requirements

### Requirement: 测试报告默认不持久化
回归/冒烟/脚本级测试 SHALL 默认只在 stdout/stderr（以及 CI 工件）输出摘要，不得在每次运行时强制生成或追加新的 Markdown 报告文件。

#### Scenario: 回归测试默认不写 TEST_REPORT.md
- **WHEN** 开发者或 CI 运行 `scripts/regression.sh --full` 或 `tests/regression_test.sh --full`，且 **未显式指定报告输出参数/环境变量**
- **THEN** 脚本只写标准输出/错误输出和未被 Git 跟踪的日志文件（例如 `logs/regression/<timestamp>/*.log`）
- AND **SHALL NOT** 创建或修改 `docs/TEST_REPORT.md` 或新的 `*_REPORT.md` / `FINAL_*.md` 报告文件
- AND 测试摘要以简洁的文本/JSON 形式可从 stdout 或 CI 日志中直接复制，用于 PR 描述或 CI 注释

#### Scenario: 显式生成一次性测试报告
- **GIVEN** 调用者需要为某次关键回归生成一个 Markdown 报告文件
- **WHEN** 运行回归脚本时显式传入约定的参数（例如 `--report` 或设置 `TEST_REPORT_OUTPUT=path`）
- **THEN** 脚本 MAY 生成一次性 Markdown 报告文件
- AND 建议将该文件作为 PR/CI 附件或本地参考，而非长期提交到仓库
- AND 文档说明这是“按需开启”的可选能力，而不是默认行为

### Requirement: 日志视为构建产物
测试与运维相关脚本生成的 `*.log` 文件 SHALL 视为构建产物，不得作为长期版本化内容提交进仓库；需要长期保留的审计信息必须使用专门定义的文件（如 JSONL）并在 specs 中显式列出。

#### Scenario: 回归日志不再提交
- **WHEN** 回归或测试脚本运行并生成 `logs/regression/<timestamp>/*.log`、`full_regression_*.log`、`webui_e2e*.log` 等文件
- **THEN** 这些日志文件 SHALL 位于 `.gitignore` 覆盖的路径/模式下
- AND 开发者/CI 默认不会将这些日志添加到 Git 提交中
- AND 若需要长期追踪某次回归的关键结论，应通过 PR 描述或规范文档中的人工摘要记录，而不是提交完整日志文件

#### Scenario: 审计日志使用专门结构化文件
- **WHEN** `scripts/reconcile.sh` 或相关工具需要记录长期可回放的审计信息
- **THEN** 它们 SHALL 使用诸如 `logs/reconcile_history.jsonl` 的结构化文件
- AND 这些文件的路径与格式在 specs 中被明确列为“允许长期存在”的审计工件
- AND 回归/测试流程不再要求把摘要追加到 `docs/TEST_REPORT.md`，而是通过读取这些 JSONL 条目或 stdout 摘要来生成 PR/CI 报告

### Requirement: 核心脚本审计文档持续维护
`docs/scripts_inventory.md` SHALL 继续作为脚本清单与审计报告的核心文档，随脚本入口与状态变更保持更新；其他一次性脚本分析/报告文档不再默认新增。

#### Scenario: 维护脚本清单而非新增报告
- **WHEN** 增加、删除或重构 `scripts/*.sh` 入口脚本
- **THEN** 运行 `scripts/scripts_inventory.sh --markdown` 以更新 `docs/scripts_inventory.md`
- AND 在代码审查中查看该文档变化，以评估脚本数量与状态是否合理
- AND 避免为单次脚本分析或调试再创建新的 `docs/XXX_REPORT.md`，除非明确标记并迁移到 `docs/history/` 作为长期案例

### Requirement: AI/自动化助手默认不生成报告文件
在本仓库中使用的 AI/自动化助手（包括通过 MCP/CLI 运行的脚本代理） SHALL 默认通过对话或控制台输出提供“简洁、可复制”的结果摘要，不得在未获明确指示的情况下创建新的报告/总结类 Markdown 文件。

#### Scenario: 默认仅对话式汇报结果
- **WHEN** AI 助手帮助运行 `scripts/regression.sh`、`scripts/smoke.sh` 或其他验证脚本
- **THEN** 它只在对话中用中文简要说明关键结果（通过/失败原因/下一步建议）
- AND **SHALL NOT** 自行创建新的 `*_REPORT.md` / `FINAL_*.md` 文档文件
- AND 若需要更详细的说明，优先引用/链接既有规范文档（如 `docs/REGRESSION_TEST_PLAN.md`、`docs/scripts_inventory.md`），而不是重复生成过程性报告

#### Scenario: 用户显式要求生成报告文件
- **GIVEN** 用户在对话或 CLI 中明确要求“生成报告文件”并指定路径/用途
- **WHEN** AI 助手或自动化脚本据此创建报告文件
- **THEN** 生成的文件 SHALL 遵守本 Specification 中的路径与命名规范（优先放在 `docs/history/` 或 PR/CI 工件路径）
- AND 内容聚焦关键信息，避免与已有规范文档重复
- AND 若该报告不再需要长期维护，建议在后续清理中删除而不是持续追加

### Requirement: 文档文件清单与正交边界
仓库 MUST 维护一份显式的文档/报告文件清单，明确每个长期存在的文档的用途、边界与类别；新增文档必须在清单中登记或放入历史目录，避免出现职责重叠、难以维护的“过程文档堆积”。

#### Scenario: 核心文档清单集中维护
- **WHEN** 贡献者打开 `docs/FILE_INVENTORY.md`
- **THEN** 其中列出根目录和 `docs/` 下所有“长期存在”的核心文档（例如 README/ARCHITECTURE/REGRESSION_TEST_PLAN/scripts_inventory 等）
- AND 每一行至少包含：文件路径、文档类型（架构/测试计划/操作手册/规范/历史案例）、面向对象（开发者/运维/使用者）和责任边界简要说明
- AND 对于不再推荐长期维护的文档类型（例如单次测试报告、阶段总结），清单中明确指出“应迁移到 `docs/history/` 或通过 PR/CI 描述替代”

#### Scenario: 文件清单检查拒绝未登记文档
- **WHEN** 执行 `scripts/file_inventory.sh --check`（或等价脚本）
- **THEN** 脚本 SHALL 读取 `docs/FILE_INVENTORY.md` 并扫描根目录与 `docs/` 下的 Markdown 文件
- AND 对于未在清单中列出、且不位于允许的历史/归档目录（例如 `docs/history/`、`docs/archive/`）中的文档，脚本 MUST 报告为“未登记文档”并以非零退出码失败
- AND 该检查脚本被集成到回归/CI 或至少作为 `scripts/scripts_inventory.sh --check` 的一部分，防止新的过程性报告文件再次进入仓库

#### Scenario: 文档内容保持正交
- **GIVEN** `docs/FILE_INVENTORY.md` 为每个核心文档提供了清晰的责任边界
- **WHEN** 提交新的文档或对现有文档进行大幅扩展
- **THEN** 评审者 SHALL 检查其内容是否与现有文档的责任边界重叠
- AND 若发现重复/冲突，应优先将内容合并回对应的“单一事实来源”文档，并在其他文件中通过链接/引用而非复制文本来复用
- AND 对于已经失去用途或完全被新文档取代的文件，应按清单标注为“待删除”，在后续清理中移除而不是无限期保留

## MODIFIED Requirements

### Requirement: Regression harness
There SHALL be a scripted way to execute the mandated clean → bootstrap → create clusters → reconcile → smoke/tests pipeline with logging.

#### Scenario: Run full regression (scripted only)
- **WHEN** `scripts/regression.sh --full` runs (internally 调用 `tests/regression_test.sh --full`)
- **THEN** it performs `scripts/clean.sh --all`, `scripts/bootstrap.sh`, 以及 `scripts/reconcile_loop.sh --once`（从 SQLite 导入的 desired state 至少包含 ≥3 kind 与 ≥3 k3d 环境），并在业务集群全部在线后额外执行一次 `scripts/reconcile.sh --prune-missing` 以移除陈旧记录
- AND it enforces the ≥3 k3d / ≥3 kind check, creates any missing environments recorded in SQLite, and fails if 数量不足
- AND it executes `scripts/smoke.sh <env>` for every non-devops environment plus `bats tests` to cover 脚本级单元测试
- AND it automatically cleans up 临时 `test-script-*` 集群、写入 `logs/regression/<timestamp>/phase-*.log`，并通过 stdout/JSON 输出本次回归的精简摘要，供 PR/CI 引用
- AND the command exits non-zero whenever 任何阶段需要人工干预或者脚本检测失败，确保“手工介入=回归失败”。

### Requirement: Regression harness invokes reconciliation
Regression tooling SHALL rely on the reconciliation runner instead of hard-coding environment creation order.

#### Scenario: Regression sequence
- **WHEN** `tests/regression_test.sh` runs
- **THEN** it performs `clean.sh`, `bootstrap.sh`, **invokes `scripts/reconcile.sh --from-db`**, validates that ≥3 kind and ≥3 k3d clusters exist, and only then continues with smoke/tests
- AND 它通过 stdout/JSON 暴露本次回归中 `reconcile.sh` 的关键信息（比如动作计数与最终状态），而不是强制将摘要追加到 `docs/TEST_REPORT.md`

### Requirement: Reconcile audit log
Every reconcile execution SHALL append a structured JSON entry for auditing.

#### Scenario: Inspect last run
- **WHEN** `scripts/reconcile.sh --last-run` executes (after at least one reconcile)
- **THEN** it reads `logs/reconcile_history.jsonl`
- AND prints timestamp, exit status, action counts, and drift details of the latest run
- AND 回归/测试流程 MAY 使用该摘要和 JSON 条目在 PR/CI 中汇报结果，但不再要求把摘要追加到 `docs/TEST_REPORT.md`
