# 域名路由与本地环境建议

本文档提供在本地/内网环境下使用“基于域名”的 HAProxy 路由、Portainer 管理以及多集群（kind/k3d）协作的建议实践。所有建议默认与当前仓库实现兼容，并可按需选择应用。

## 基础参数与命名
- BASE_DOMAIN：基础域名后缀，最终入口形如 `<env>.<BASE_DOMAIN>`。默认 `local`，示例：`dev.local`、`uat.local`、`prod.local`。
- HAPROXY_HOST：对外访问的主机名或 IP，用于 Portainer HTTP→HTTPS 的 301 Location。可为内网 IP 或已解析的域名。

建议：
- 保持 `BASE_DOMAIN=local` 作为本地默认；需要对外演示时，另建子域（如 `lab.example.com`），再将 `<env>.lab.example.com` 解析到 HAProxy 所在主机。
- `HAPROXY_HOST` 如为域名，请在 DNS/hosts 中指向 HAProxy 宿主机 IP。

## 域名解析与证书
- 解析：在开发机或内网 DNS/hosts 中添加记录：`<HAProxy_IP>  dev.<BASE_DOMAIN> uat.<BASE_DOMAIN> prod.<BASE_DOMAIN>`。
- 证书：
  - 本地开发阶段，Portainer HTTPS 使用容器内置证书（自签名）；浏览器可忽略告警。
  - 内网/演示环境建议使用自签名自管 CA 或 ACME DNS 验证签发通配证书（`*.lab.example.com`），并挂载到 `compose/haproxy/certs/` 中的 `gw.pem`。

## 路由与后端
- HAProxy：
  - 监听 23080（HTTP）：按 Host 路由到对应集群后端（NodePort 30080）。
  - 监听 23380/23343：对外暴露 Portainer（HTTP 301 → HTTPS 透传）。
- 集群侧：
  - 推荐直接使用 NodePort（30080）暴露最小入口，避免耦合；如需 Ingress 再行安装（如 Traefik/Ingress-Nginx）。
  - 如果安装 Ingress，仍建议保持 NodePort 一致（30080），以便 HAProxy 无需改动。

## 多集群管理（Portainer）
- 每个集群自动部署 Portainer Agent 并通过本机端口转发注册到 Portainer。
- Endpoint 命名规则：`类型_环境`，即 `Kind_<env>`（kind）或 `k3d_<env>`（k3d），已在脚本中实现。

## 自动化与验证
- 一键启动基础环境：`scripts/bootstrap.sh`（Portainer + HAProxy）
- 创建/删除集群：`scripts/create_env.sh -n <env> -p kind|k3d`、`scripts/delete_env.sh -n <env>`
- 路由编辑：`scripts/haproxy_route.sh add|remove <env>`（幂等，写回配置后自动重载）
- 强制验证与报告：
  - `scripts/smoke.sh <env>` 会在 `docs/TEST_REPORT.md` 追加记录：
    - `http://$HAPROXY_HOST:23380` → 301
    - `https://$HAPROXY_HOST:23343` → 200
    - `-H 'Host: <env>.$BASE_DOMAIN' http://$HAPROXY_HOST:23080` → 200/服务返回码
  - 也可使用 MCP 浏览器访问 `https://$HAPROXY_HOST:23343` 目测 Portainer 为 200。

## 性能与资源
- kind/k3d 在开发机资源有限：建议按需只拉起所需集群，或先建 dev 验证通过再扩展 uat/prod。
- 镜像预热：
  - `tools/maintenance/prefetch_images.sh <manifest> <cluster>` 将清单内 image 预拉并导入节点（解决离线/限网环境镜像拉取失败问题）。
  - 例如：`tools/maintenance/prefetch_images.sh manifests/traefik/traefik.yaml dev`

## 故障排查
- Portainer 301/200 不通：
  - 检查 `docker compose -f compose/haproxy/docker-compose.yml ps`；
  - 确认 `compose/haproxy/haproxy.cfg` 权限为 644；
  - `scripts/bootstrap.sh` 会基于 `HAPROXY_HOST` 写入 301 目标，可重新执行。
- 域名路由 503：
  - 多为后端服务未就绪或镜像拉取失败（限网）；使用 `prefetch_images.sh` 预热镜像后再部署；
  - 确认后端 NodePort 为 30080，且 `scripts/haproxy_route.sh add <env>` 已写入正确节点 IP。
- 重复 backend 或 ACL：
  - 运行 `scripts/haproxy_route.sh add <env>` 前会先自动 remove；如仍有残留，直接 `remove` 再 `add`。

## 验收建议（Checklist）
1. 启动基础环境：`scripts/bootstrap.sh`
2. 验证 Portainer：
   - `curl -I http://$HAPROXY_HOST:23380` 应为 301
   - `curl -kI https://$HAPROXY_HOST:23343` 应为 200
3. 验证域名路由（至少 1 个集群，如 dev）：
   - `curl -I -H 'Host: dev.$BASE_DOMAIN' http://$HAPROXY_HOST:23080`
4. 记录报告：`scripts/smoke.sh dev`（输出追加到 `docs/TEST_REPORT.md`）


### Portainer 端点未出现（Kind_dev/k3d_<env> 看不到）
- 核心原因：Portainer 容器无法访问本机端口转发（仅监听在 127.0.0.1）。需绑定 0.0.0.0 并使用容器可达地址注册。
- 快速修复步骤：
  1) 停止已有的 port-forward（避免端口占用）：
     `pgrep -af "kubectl.*port-forward.*portainer-agent.*--context kind-dev" | awk '{print $1}' | xargs -r kill -9`
  2) 以 0.0.0.0 监听重新启动：
     `nohup kubectl --address 0.0.0.0 --context kind-dev -n portainer port-forward svc/portainer-agent 19001:9001 >data/pf-agent-dev.log 2>&1 &`
  3) 选择 Portainer 容器内可达的宿主地址 PF_HOST：优先 `HAPROXY_HOST`；未配置时可回退 Docker bridge 网关：
     `docker network inspect bridge --format '{{ (index .IPAM.Config 0).Gateway }}'`
  4) 验证连通性（返回 200/405/400 均表示可达）：
     `curl -skI https://$PF_HOST:19001/ping`
  5) 重新注册端点（类型_环境 命名）：
     `scripts/portainer.sh add-endpoint Kind_dev tcp://$PF_HOST:19001`
  6) 查看端点：
     `curl -skH "Authorization: Bearer $(scripts/portainer.sh api-login)" https://127.0.0.1:23343/api/endpoints | jq -r '.[].Name'`
- 预防建议：
  - `scripts/create_env.sh` 已在注册前检测 `/ping`，并在需要时使用 0.0.0.0 监听与 `HAPROXY_HOST` 注册；若自定义了网段或容器网络，请确保 `HAPROXY_HOST` 在 Portainer 容器内可达。
