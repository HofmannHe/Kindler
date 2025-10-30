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

## HAProxy 代理模式规范

### 统一要求
- **HAProxy 采用七层代理暴露 Web 服务，不得使用四层代理**
- **所有服务均由 HAProxy 实现 80 到 443 的跳转**
- **443 的 HTTPS 服务由 HAProxy 负责终止，转为 HTTP**
- **根据后端服务类型重新发起 HTTP/HTTPS 服务，无特殊情况优先使用 HTTP 后端**

### 实现细节
1. **Frontend 配置**
   - `fe_http` (80端口): HTTP 模式，支持 Host 头路由
   - `fe_https` (443端口): HTTP 模式，支持 Host 头路由和 SSL 终止

2. **SSL 终止**
   - HAProxy 在 443 端口终止 SSL 连接
   - 使用自签名证书或配置的 SSL 证书
   - 将 HTTPS 请求转换为 HTTP 请求转发给后端

3. **后端服务**
   - 优先使用 HTTP 后端服务
   - 仅在必要时使用 HTTPS 后端（如 Portainer 的 9443 端口）
   - 所有后端配置为 HTTP 模式

4. **路由规则**
   - 基于 Host 头进行路由
   - 支持通配符域名匹配
   - 默认后端返回 404 错误
