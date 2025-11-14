## Why
- 当通过 WebUI 触发 `scripts/create_env.sh` 时，脚本在 `kindler-webui-backend` 容器内运行，`ROOT_DIR` 解析为镜像内的 `/app`，无法访问宿主机 `compose/infrastructure/haproxy.cfg`。
- HAProxy 路由更新写入的是容器内的私有文件，宿主机上的 HAProxy 从未得到 test/test1 等新集群的 ACL/backend，导致 whoami 域名 404，而 ArgoCD/Portainer 仍显示集群健康。
- 回归脚本全部在宿主机执行，未覆盖“通过 WebUI 调用脚本”的路径，因此缺乏自动化检测。

## What Changes
1. 为所有脚本提供 `KINDLER_ROOT` 覆盖入口，若该变量存在则用它作为仓库根目录，以便容器内脚本可以指向宿主机路径。
2. 在 `compose/infrastructure/docker-compose.yml` 中为 `kindler-webui-backend` 挂载整个仓库目录到 `/workspace/kindler`，并设置 `KINDLER_ROOT=/workspace/kindler`，确保 WebUI 脚本与宿主机共享同一套文件（compose/docs/logs）。
3. 对现有的 test/test1 集群重新运行 HAProxy route 同步（或 `haproxy_sync.sh --prune`），验证 whoami 域名可访问，并补充回归记录。
4. 补充 `tooling-scripts` 规格，明确“脚本从任何容器/路径运行都必须指向宿主机仓库”以及“WebUI 创建集群时必须同时刷新 HAProxy 路由”。

## Impact
- `scripts/lib/lib.sh` 初始化逻辑、docker-compose 定义、HAProxy 配置刷新和相关文档/spec。
- 需要重启 `kindler-webui-backend` 容器以应用新挂载，随后 rerun full regression（含 WebUI 场景）来确认。
