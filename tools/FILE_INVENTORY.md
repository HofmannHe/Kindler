# FILE_INVENTORY（tools 目录）

> 本清单用于管理 `tools/` 目录中需要长期保留的运维/维护工具及其子目录边界，采用目录级白名单模式；单个脚本的用途以脚本头部注释和 `docs/scripts_inventory.md` 为准。

## 使用约定

- `Path` 为相对于仓库根目录的路径。
- 本清单聚焦 `tools/` 下的核心子目录与入口脚本集合，说明它们在整体生命周期中的角色；具体脚本通过自身头部的 Description/Usage/Category/Status 进行补充说明。
- 新增长期存在的工具子目录时，必须在本文件中补充条目；一次性调试脚本建议放在临时分支或本地，不应提交到仓库。

## tools/ 目录结构

| Path                 | Type        | Audience        | Scope                                                                                         | Status  |
|----------------------|-------------|-----------------|-----------------------------------------------------------------------------------------------|---------|
| `tools/`             | tools-root  | developer, ops  | 存放与集群重配置、Git/ArgoCD 修复、诊断等相关的辅助脚本集合，不直接作为用户入口命令。       | primary |
| `tools/git/`         | git-tools   | developer       | 管理 Git 分支策略与从 SQLite 同步 GitOps 仓库分支的工具集合，例如 `sync_git_from_db.sh` 等。 | primary |
| `tools/db/`          | db-tools    | developer, ops  | 针对数据库迁移/校验的工具脚本目录，目前主要服务于 SQLite 相关操作与一致性检查。             | primary |
| `tools/setup/`       | setup-tools | developer, ops  | DevOps 基础设施初始化与环境准备相关工具目录，例如 devops 集群 bootstrap 辅助脚本等。        | primary |
| `tools/legacy/`      | legacy      | developer       | 历史兼容或已替换的早期工具脚本，保留用于排障参考，后续可按需删除或归档。                     | legacy  |

