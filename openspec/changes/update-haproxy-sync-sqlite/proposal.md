## Why
当前 `scripts/haproxy_sync.sh` 与相关修复脚本仍依赖 `config/environments.csv` 作为数据源，这与“SQLite 为唯一真实数据源”的规范不一致，存在数据漂移与幂等性风险（CSV 与 DB 不一致时会产生错误路由）。

## What Changes
- 将 `haproxy_sync.sh` 的源切换为 `SQLite/clusters` 表（不可用时回退到 CSV）；支持 `--prune` 基于 DB 清理陈旧路由。
- 调整 `fix_haproxy_routes.sh` 与 `haproxy_route.sh`：优先从 DB 读取必要信息（provider、子网/http_port 等），CSV 仅作为显式回退路径。
- 保持 `devops` 环境排除规则与 `KINDLER_NS` 命名空间后缀逻辑；保持路由生成的幂等与并发安全（文件锁 + 验证配置后再 reload）。
- 覆盖/补充测试：bats 验证 DB 源同步、`--prune` 生效、配置验证无 ALERT、路由仅对实际存在的集群生成。
- 文档同步：README(中英) 与架构文档标注“HAProxy 路由以 SQLite 为准”。

## Impact
- 受影响能力：HAProxy 路由同步（routing）；GitOps 文档；测试脚本。
- 受影响代码：`scripts/haproxy_sync.sh`、`tools/fix_haproxy_routes.sh`、`scripts/haproxy_route.sh`、`tests/04_haproxy_cfg.bats`、`tests/haproxy_test.sh` 等。
- 兼容性：默认兼容（DB 不可用时回退 CSV）；建议在 bootstrap 完成后始终具备 DB。
