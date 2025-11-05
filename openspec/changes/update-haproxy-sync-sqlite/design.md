## Context
- 现状：`scripts/haproxy_sync.sh` 与 `scripts/fix_haproxy_routes.sh` 主要依赖 `config/environments.csv` 读取环境列表与端口，`haproxy_route.sh` 在个别字段（provider）已支持 DB 优先，但 subnet/http_port 等仍走 CSV。
- 目标规范：运行期以 SQLite `/data/kindler-webui/kindler.db` 的 `clusters` 表为唯一真实数据源；CSV 仅在 `bootstrap.sh` 初始化导入，运行期不再作为主源。
- 约束：
  - devops 为管理集群，不生成业务路由；
  - 路由与配置变更应保持幂等与并发安全；
  - 保持最小变更原则，维持已验证的网络拓扑（HAProxy → NodePort → Traefik）。

## Goals / Non-Goals
- Goals
  - `haproxy_sync.sh` 与 `fix_haproxy_routes.sh` 改为 DB 驱动（DB→CSV 回退）。
  - `haproxy_route.sh` 对 subnet/http_port 等字段改为 DB 优先、CSV 回退。
  - 支持 `--prune` 以 DB 为准清理陈旧路由；reload 前校验无 ALERT。
  - 保持 devops 排除，支持 `KINDLER_NS` 后缀隔离。
- Non-Goals
  - 不改变 whoami 的 GitOps 流程与 ApplicationSet 行为。
  - 不变更 HAProxy 静态管理域名（Portainer/ArgoCD）逻辑。

## Decisions
- Source-of-truth：运行期以 SQLite `clusters` 表为准，提供 DB 不可用时的 CSV 回退路径，避免在早期 bootstrap 阶段阻塞。
- 发现与过滤：仅为“实际存在且可访问”的业务集群生成路由（`kubectl --context <ctx> get nodes` 成功）；过滤 `devops`。
- 端口：默认 NodePort `30080`；若 DB 提供自定义 `node_port` 则透传；`http_port` 仅在极端 fallback 使用。
- 网络连接：k3d 优先连接专用 `k3d-<name>`，其次 `k3d-shared`；kind 连接 `kind` 网络；保持现有逻辑与幂等性。
- 并发：继续使用 `flock` 文件锁，reload 前执行 `haproxy -c -f` 校验，遇 ALERT 回滚。

## Risks / Trade-offs
- 风险：DB 不可用导致路由不同步；缓解：CSV 回退 + 下一次 DB 恢复后再次同步覆盖。
- 风险：多进程并发修改 haproxy.cfg 产生竞态；缓解：全程持锁 + 校验 + 失败回滚。
- 权衡：使用 `kubectl` 探测上下文可用性会增加执行时间；换取更稳健的“仅对真实存在的集群生成路由”。

## Migration Plan
1) 实施脚本改造（DB 优先、CSV 回退），不改变现有入口与参数。
2) 在非生产分支（设置 `KINDLER_NS`）下执行 `clean.sh && bootstrap.sh`；创建 ≥3 kind 与 ≥3 k3d 环境，运行 `haproxy_sync.sh --prune`。
3) bats 与冒烟：校验 HAProxy 无 ALERT、路由生效、域名可达；运行 `scripts/smoke.sh <env>` 并记录测试报告。
4) 验证 Portainer 管理正常、ArgoCD 与 ApplicationSet 不受影响。

## Open Questions
- 是否需要在 `clusters` 表增加显式的 `haproxy_route_enabled` 布尔字段？当前按“存在且可访问的业务集群=需路由”的默认策略处理。
- `http_port` 在当前架构下仅用于极端回退路径，是否可以后续完全移除？

