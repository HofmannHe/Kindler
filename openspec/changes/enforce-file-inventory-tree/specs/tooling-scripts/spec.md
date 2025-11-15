## ADDED Requirements

### Requirement: 层次化文件清单树
仓库 MUST 从根目录开始维护一棵“文件清单树”，通过 FILE_INVENTORY/FILE_PLAN 等局部清单描述各级目录与关键文件的用途与边界，并与全局严格白名单协同工作。

#### Scenario: 从根目录向下追踪文件职责
- **GIVEN** 仓库已维护 `FILE_INVENTORY_ALL.md` 作为 `git ls-files` 的严格白名单
- **WHEN** 贡献者阅读根目录及子目录中的 FILE_INVENTORY/FILE_PLAN（例如根目录的目录级清单、`docs/FILE_INVENTORY.md`、`examples/FILE_INVENTORY.md`、`webui/FILE_INVENTORY.md`、`tools/FILE_INVENTORY.md` 等）
- **THEN** 可以从根目录开始，自顶向下追踪到任意一个长期存在的文件或子目录，了解它的 Purpose（用途）、Owner（责任人/角色）与 Scope（责任边界）
- AND 每个局部清单只描述“当前目录下的文件与直接子目录”，更深层级由其下游目录的清单继续细化，整体构成一棵无环的清单树
- AND 对于一次性报告、临时日志等不应长期提交的文件，清单中要么明确标记为 `legacy`/历史案例，要么通过 `.gitignore` 避免其进入 `FILE_INVENTORY_ALL.md`

#### Scenario: FILE_INVENTORY_ALL 与局部清单协同
- **WHEN** 运行 `scripts/file_inventory_all.sh --check`
- **THEN** 它验证 `FILE_INVENTORY_ALL.md` 与 `git ls-files` 完全一致，确保没有“幽灵文件”
- AND 对于 `FILE_INVENTORY_ALL.md` 中列出的任意路径，审阅者可以通过查阅相应目录的 FILE_INVENTORY/FILE_PLAN 或上层目录条目，找到该文件/目录的用途说明与责任边界
- AND 新增长期存在的文件/目录时，变更评审须要求在对应局部清单中补充 Purpose/Owner/Scope，不得仅在 `FILE_INVENTORY_ALL.md` 中裸列路径

### Requirement: 目录规模审计（Phase 1）
tooling 脚本 SHALL 提供一个轻量的目录规模审计能力，用于统计每个目录下的文件数量并标记超过推荐上限（例如 15 个文件）的目录，为后续结构重构提供依据。

#### Scenario: 运行目录规模审计脚本
- **WHEN** 贡献者执行 `scripts/file_tree_audit.sh --check`（名称示例，实际脚本路径在实现阶段确定）
- **THEN** 脚本基于 `git ls-files` 构建当前仓库的目录树，按相对路径统计每个目录下的文件数量（排除 `.git/`、`worktrees/` 等不受管路径）
- AND 至少以 WARNING 形式列出文件数超过默认上限（例如 15 个）的目录，按文件数量从高到低排序，便于识别需要拆分或迁移的热点目录
- AND 默认运行时 **不依赖** Docker/k3d/kind/网络，只是本地结构审计工具，不会改变现有 clean/bootstrap/reconcile/smoke/regression 流程的行为
- AND 后续变更 MAY 在充分清理与重构后，将该脚本扩展为在严格模式下对超限目录返回非零退出码，但本次变更仅要求审计与报告能力

