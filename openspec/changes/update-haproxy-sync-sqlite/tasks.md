## 1. Implementation
- [x] 1.1 `haproxy_sync.sh` 改为从 SQLite 读取 `clusters`（排除 devops；仅对“实际存在且可访问”的集群生成）
- [x] 1.2 支持 `--prune`：以 DB 为准清理缺失环境的 ACL/后端
- [x] 1.3 `fix_haproxy_routes.sh` 改为 DB 驱动（保留 CSV 回退）
- [x] 1.4 `haproxy_route.sh` 读取必要字段优先来自 DB（provider、子网/http_port 等），并维持并发安全与配置校验
- [x] 1.5 单元/脚本测试：新增或更新 bats 覆盖 DB 源、`--prune`、配置校验、幂等
- [x] 1.6 文档：README/README_CN 与架构文档同步“HAProxy 以 SQLite 为准”
- [x] 1.7 冒烟：`clean.sh && bootstrap.sh` 后创建 ≥3 kind 和 ≥3 k3d 环境，验证路由与 Portainer 管理均正常（本次验证：k3d=dev/uat/prod；kind=devk/uatk/prodk；whoami 域名均 200）

## 2. Hardening & Regression fixes
- [x] 2.1 将 `compose/infrastructure/haproxy.cfg` 的动态区块置空（ACL/USE_BACKEND/BACKENDS 仅由脚本生成，避免遗留引用导致 HAProxy 重启循环）
- [x] 2.2 在 `setup_devops.sh` 中重写 `be_argocd` 后端为当前 devops 节点 IP + NodePort（避免硬编码 IP 导致 ArgoCD 不可达）
- [x] 2.3 `bootstrap.sh` 默认以 Edge Agent 将 `devops` 注册到 Portainer（`REGISTER_DEVOPS_PORTAINER=0` 可关闭），解决“Portainer 中看不到 devops 集群”的可观测性问题
- [x] 2.4 回归脚本 `tests/regression_test.sh` 增加 HAProxy/Portainer 容器重启计数输出，用于区分“脚本期望重载”和“异常重启”
