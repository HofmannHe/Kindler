## ADDED Requirements

### Requirement: Scripts honor shared repo root across containers
脚本 **MUST** 支持通过环境变量将仓库根目录固定到宿主机路径，以便在容器 (如 WebUI Backend) 中执行时仍可修改宿主机上的 HAProxy/compose/docs。

#### Scenario: Fall back to KINDLER_ROOT
- **GIVEN** `kindler-webui-backend` 通过 Docker volume 将宿主机仓库挂载到 `/workspace/kindler`
- **WHEN** 该容器内运行 `scripts/create_env.sh`
- **THEN** `lib.sh` 读取 `KINDLER_ROOT=/workspace/kindler` 并把 `compose/infrastructure/haproxy.cfg`、`docs/TEST_REPORT.md` 等路径解析到宿主机目录
- AND HAProxy 路由、文档、日志都与宿主机视图保持一致，无需再复制文件到容器内镜像。

### Requirement: WebUI-driven cluster creation updates HAProxy
通过 WebUI 或 API 创建集群时，HAProxy 动态路由 **MUST** 立即更新，所创建的域名 (`whoami.<env>.<BASE_DOMAIN>`) 可访问。

#### Scenario: WebUI cluster route available
- **GIVEN** 用户在 WebUI 勾选 provider 并创建 `test`/`test1` 集群
- **WHEN** 操作完成后调用 `curl -H "Host: whoami.test.$BASE_DOMAIN" http://$HAPROXY_HOST`
- **THEN** 返回 200，HAProxy 配置中存在 `host_test` ACL 与 `backend be_test`
- AND 该流程完全脚本化（`haproxy_route.sh`/`haproxy_sync.sh`）且写入宿主机配置文件。
