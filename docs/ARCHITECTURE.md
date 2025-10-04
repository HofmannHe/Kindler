# 架构方案（HAProxy + dev/uat/prod 多集群）

目标
- 在本机快速模拟统一入口与多环境集群，方便功能验证与联调。

拓扑
- HAProxy（容器，监听宿主 80/443）
  - `dev.local` -> 127.0.0.1:18080 / 18443（dev 集群入口）
  - `uat.local` -> 127.0.0.1:28080 / 28443（uat 集群入口）
  - `prod.local` -> 127.0.0.1:38080 / 38443（prod 集群入口）
- 集群入口
  - k3d：创建时使用 `--port <host>:<container>@loadbalancer` 暴露 80/443
  - kind：在 `clusters/kind/*.yaml` 用 `extraPortMappings` 暴露 80/443 到宿主端口

域名与访问
- 通过 `Host` 头或本机 `hosts`：`127.0.0.1 dev.local uat.local prod.local`
- 也可直接访问端口：`http://127.0.0.1:18080`（dev）等

实现要点（最小可用）
- 优先使用公共镜像：`haproxy`, `ingress-nginx` 或 k3s 默认 `traefik`
- 使用 `Makefile` 与 `scripts/` 抽象差异（`k3d image import` vs `kind load docker-image`；端口映射差异）

验证标准（整体）
- `dev.local/uat.local/prod.local` 通过 HAProxy 可返回 200
