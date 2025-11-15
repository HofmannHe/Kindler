# FILE_INVENTORY（examples 目录）

> 本清单用于管理 `examples/` 目录中需要长期保留的 Markdown 文档，采用严格白名单模式；未在此列出的 `.md` 文件视为异常或待清理/迁移。

## 使用约定

- `Path` 为相对于仓库根目录的路径。
- 本清单仅覆盖 `examples/` 及其一级子目录（例如 `examples/kindler-config/`）中的 Markdown 文档。
- 新增示例文档时，必须在本文件中补充条目，或将一次性说明迁移到 `docs/history/` 中的历史案例文档。

## examples/ 目录文档

| Path                                   | Type          | Audience        | Scope                                                 | Status  |
|----------------------------------------|---------------|-----------------|--------------------------------------------------------|---------|
| `examples/kindler-config/README.md`    | example-guide | developer, user | Kindler 配置示例说明，展示典型 `.kindler.yaml` 的用法与字段含义。 | primary |

