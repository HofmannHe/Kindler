# 本地轻量环境（Portainer + HAProxy + kind/k3d）

目标：简单、快速、够用。以 Portainer CE 统一管理容器与轻量集群；HAProxy 提供统一入口（Portainer: 23380/23343；集群 NodePort 路由: 23080）。

## 目录结构
- `manifests/`：Kubernetes 清单（示例见 `manifests/demo.yaml`）
- `clusters/`：轻量集群配置（kind/k3d）
  - 版本镜像通过 `config/clusters.env` 管理：
    - `KIND_NODE_IMAGE`（默认 `kindest/node:v1.31.12`）
    - `K3D_IMAGE`（默认 `rancher/k3s:stable`）
- `compose/`：`haproxy` 与 `portainer` 的 Compose 配置
- `scripts/`：辅助脚本（Portainer、集群管理）
- `tests/`：基础测试

## 快速开始
1) 设置密码：在 `config/secrets.env` 中设置 `PORTAINER_ADMIN_PASSWORD`（默认 `admin123`）。
2) 配置对外访问主机名/IP（用于 Portainer 301 跳转）：在 `config/clusters.env` 中设置 `HAPROXY_HOST`（支持 IP 或域名，默认 `192.168.51.30`）。
3) 一键启动基础环境：`scripts/bootstrap.sh`（启动 Portainer + HAProxy，并套用 `HAPROXY_HOST` 到重定向配置）。
4) 访问 Portainer：
   - `http://<HAPROXY_HOST>:23380`（301 重定向）
   - `https://<HAPROXY_HOST>:23343`（自签名证书，浏览器可忽略告警）
5) 创建集群：`scripts/create_env.sh -n dev -p kind`（也支持 `-p k3d`）。
   - 自动：注册 Portainer Agent、添加 HAProxy 反向代理（NodePort 默认为 30080，可在 CSV 指定；域名：`<env>.<BASE_DOMAIN>`）。
   - 如不需要自动注册：可加 `--no-register-portainer` 或 `--no-haproxy-route`。


- 同步 HAProxy 路由：`scripts/haproxy_sync.sh [--prune]`（从 CSV 生成/更新域名路由，--prune 清理 CSV 之外的条目）

清理：
- 删除单个集群：`scripts/delete_env.sh -n <env> [-p kind|k3d]`（会同步清理 Portainer Endpoint、HAProxy 路由、端口转发）。
- 全量清理：`scripts/clean.sh`（停止并移除 HAProxy/Portainer、终止 port-forward、删除 dev/uat/prod/ops 集群与命名卷）。

## 端口与验证
- Portainer：HTTP `23380`（301） → HTTPS `23343`
- K8s Ingress（Traefik NodePort）：HTTP `23080`（按 `name.<BASE_DOMAIN>` Host 转发到各集群 `30080`）
- 验证：
  - `curl -I http://$HAPROXY_HOST:23380` 应为 `301`
  - `curl -kI https://$HAPROXY_HOST:23343` 应为 `200`
  - `curl -H 'Host: dev.$BASE_DOMAIN' -I http://$HAPROXY_HOST:23080` 应为 `200` 或反向代理服务返回码

## 说明
- HAProxy 路由：`scripts/haproxy_route.sh add <name>` 会：
  - 在 `fe_kube_http` 添加 `name.<BASE_DOMAIN>` 的 Host ACL；
  - 新建 `backend be_<name>` 指向对应集群节点容器 IP 的 `30080`（Traefik NodePort）。
- Portainer 管理：
  - `scripts/portainer.sh up` 启动/更新 Portainer；
  - `scripts/portainer.sh add-endpoint <name> <addr>` 注册集群 Agent；
  - 管理密码由 `config/secrets.env` 的 `PORTAINER_ADMIN_PASSWORD` 注入。

## 环境定义（CSV）
- 通过 `config/environments.csv` 配置环境默认参数；命令行传参可覆盖。
- CSV 列：`env,provider,node_port,pf_port,register_portainer,haproxy_route,http_port,https_port`
- 示例：
```
# env,provider,node_port,pf_port,register_portainer,haproxy_route,http_port,https_port
dev,kind,30080,19001,true,true,18090,18443
uat,kind,30080,29001,true,true,28080,28443
prod,kind,30080,39001,true,true,38080,38443
```
- 使用示例：
  - `scripts/create_env.sh -n dev`（使用 CSV 默认）
  - `scripts/create_env.sh -n dev --node-port 30081 --no-register-portainer`（覆盖默认）
