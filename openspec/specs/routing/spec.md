# routing Specification

## Purpose
TBD - created by archiving change update-haproxy-sync-sqlite. Update Purpose after archive.
## Requirements
### Requirement: HAProxy 路由同步以 SQLite 为唯一数据源
系统 MUST 以 SQLite `clusters` 表为路由生成与清理的唯一真实数据源；当 DB 临时不可用时 MAY 回退到 `config/environments.csv`，并在 DB 恢复后以 DB 优先对齐状态。

#### Scenario: 从 DB 读取并生成路由
- **WHEN** DB 可用且存在一个业务集群记录（非 `devops`）且实际存在（kubectl context 可访问）
- **THEN** 生成对应的动态 ACL、use_backend 与 backend，并将 HAProxy 连接到正确的 Docker 网络

#### Scenario: DB 不可用时回退到 CSV
- **WHEN** DB 不可用
- **THEN** 系统 MAY 使用 `config/environments.csv` 生成路由；DB 恢复后再次运行时以 DB 为准

#### Scenario: `--prune` 基于 DB 清理陈旧路由
- **WHEN** 运行同步脚本带 `--prune`
- **THEN** 路由中存在但 DB 缺失的环境 SHALL 被移除（排除 `devops`）

#### Scenario: 并发安全与配置校验
- **WHEN** 多个同步/路由脚本并发运行
- **THEN** 通过文件锁避免竞态；在 reload 前 MUST 执行配置校验（无 ALERT）

#### Scenario: 避免污染管理环境
- **WHEN** 目标环境为 `devops`
- **THEN** SHALL NOT 生成动态路由（管理域名通过静态路由处理）

#### Scenario: 支持命名空间后缀隔离
- **WHEN** 设置 `KINDLER_NS=<ns>`
- **THEN** 生成的路由 SHALL 使用追加命名空间后缀的环境名，避免与主环境冲突

