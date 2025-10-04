# 开发计划（HAProxy + 多集群 + GitOps）

目标与原则
- 原则：简单、快速、够用；公共镜像优先；脚本与 Makefile 统一入口；每步可独立验证。

统一变量

步骤 1：目录与占位
- 动作：补充 `compose/`（HAProxy/ArgoCD/Portainer）、`manifests/ingress/`、`clusters/{k3d,kind}/`、`config/`（GitOps 配置）。
- 验收：目录存在；`README` 说明新增目录用途。

步骤 2：三集群创建脚本
- 动作：`scripts/cluster.sh` 支持 `create|delete|kubeconfig|import`，按环境与 provider 创建 `dev/uat/prod`。
- 验收：三套集群均可创建并 `kubectl --context <env> get nodes` 就绪；可删除并重复创建。

步骤 3：集群入口端口映射
- 动作：为每个集群暴露 80/443 到宿主不同端口（如 dev: 18080/18443，uat: 28080/28443，prod: 38080/38443）。k3d 用 `--port`，kind 用 `extraPortMappings`。
- 验收：每个集群内部部署的 `nginx` 通过对应宿主端口可被 `curl` 访问返回 200。

步骤 4：HAProxy 统一入口
- 动作：`compose/haproxy` 提供 `haproxy.cfg`，按域名路由到对应宿主端口（如 `dev.local`→`127.0.0.1:18080`）。
- 验收：`docker compose up -d haproxy` 后，`curl -H "Host: dev.local" http://127.0.0.1/` 返回 dev 集群内容；`uat.local`、`prod.local` 同理。


步骤 6：GitOps 仓库可配置
- 验收：修改 `gitops.env` 后重新执行脚本，应用指向新仓库并完成同步。

步骤 8：Makefile 统一入口
- 验收：`make up` 全部成功；`make status` 显示各组件健康；`make down` 可完全清理并可再次 `make up`。

步骤 9：最小冒烟与回归

说明
- 每步可独立执行；如仅需单集群或仅需 HAProxy，可在相应步骤停下即可满足快速验证目的。
