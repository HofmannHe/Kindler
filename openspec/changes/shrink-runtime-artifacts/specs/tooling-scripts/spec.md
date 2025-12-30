## ADDED Requirements

### Requirement: Runtime artifacts and experiments SHALL not persist
临时实验实现或过渡版本文件（例如 `*.phase2-attempt`）SHALL NOT 长期驻留在运行时代码目录中；需要保留的思路应迁移到文档或 history 目录，由 canonical 实现文件承载真实行为。

#### Scenario: Remove experimental WebUI backend files
- GIVEN WebUI 后端存在 `webui/backend/app/api/clusters.py.phase2-attempt` 等实验实现文件
- WHEN `openspec` 变更 `shrink-runtime-artifacts` 完成实施
- THEN 这些实验文件不再存在于版本库中
- AND 对应逻辑要么已经合并进 canonical 文件，要么在文档中有简要记录
- AND `FILE_INVENTORY_ALL.md` 同步删除相关条目，`scripts/file_inventory_all.sh --check` 通过

### Requirement: Sensitive git config MUST use examples only
含真实凭据或近似真实凭据的 Git 配置文件（例如 `config/git.env`）MUST NOT 提交到版本库中；仅允许提交 `*.example` 模板，并要求脚本优先从本地未提交文件或环境变量读取。

#### Scenario: Git env configuration sanitized
- GIVEN `config/git.env.example` 提供 GitOps 仓库配置模板
- WHEN 运行 `git ls-files config/git.env`
- THEN 输出为空（该文件不再被 Git 跟踪）
- AND 相关脚本文档明确说明“复制 `config/git.env.example` 为本地 `config/git.env` 并填充凭据”的流程

### Requirement: Broken tests MUST be resolved or retired
显式标记为 `broken` 的测试脚本 MUST NOT 长期停留在主测试目录中；应在合理的时间内修复并纳入正式测试流程，或迁移到 history 目录作为案例，或从版本库中删除。

#### Scenario: Broken service test resolved or removed
- GIVEN `tests/services_test.sh.broken` 目前被标记为 broken
- WHEN 变更 `shrink-runtime-artifacts` 完成后查看 `tests/` 目录
- THEN 该文件要么被修复并更名/接入测试入口
- OR 被迁移到 `docs/history/` 或从仓库删除
- AND `FILE_INVENTORY_ALL.md` 中不再保留其旧路径条目
