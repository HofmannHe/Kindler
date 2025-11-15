# FILE_INVENTORY（webui 目录）

> 本清单用于管理 `webui/` 目录中需要长期保留的说明类文件与子目录边界，采用严格白名单模式；未在此列出的 Markdown 说明文件视为异常或待清理/迁移。

## 使用约定

- `Path` 为相对于仓库根目录的路径。
- 本清单聚焦 `webui/` 目录中的 README 类文档与核心子目录职责说明；代码文件由各自模块内的 README 注释/类型系统承担自解释职责。
- 新增 WebUI 相关的长期说明文档时，必须在本文件中补充条目；一次性调试记录应放在 PR/CI 或本地，而不是提交到仓库。

## webui/ 目录文档与子目录

| Path                       | Type          | Audience        | Scope                                                                                   | Status  |
|----------------------------|---------------|-----------------|------------------------------------------------------------------------------------------|---------|
| `webui/README.md`          | webui-guide   | developer       | 说明 Kindler WebUI 的目录结构、开发流程与本地运行方式，是 WebUI 开发与调试的入口文档。   | primary |
| `webui/README_POSTGRESQL.md` | webui-db-legacy | developer     | 记录早期 WebUI 与 PostgreSQL 集成方案，仅作历史参考；当前实现以 SQLite 方案为准。       | legacy  |
| `webui/frontend/`          | webui-frontend| developer       | 前端代码与构建配置所在目录，负责 Web UI 展示层，不直接管理集群生命周期脚本。           | primary |
| `webui/backend/`           | webui-backend | developer       | 后端 API 与数据库访问逻辑所在目录，负责读取 SQLite 并为 WebUI 提供集群视图与操作接口。 | primary |
| `webui/tests/`             | testing       | developer       | 覆盖 WebUI 前后端的自动化测试目录，不存放长期报告，仅保留测试代码与必要的 fixtures。   | primary |

