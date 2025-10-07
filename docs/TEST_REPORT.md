## 2025-10-04: K3D 集群 sslip.io 域名解析与 HAProxy 路由验证

### 测试环境
- Portainer CE: 最新版本
- HAProxy: 2.9
- K3D 集群: dev-k3d, uat-k3d, prod-k3d (v1.31.5+k3s1)
- 域名配置: BASE_DOMAIN=192.168.51.30.sslip.io
- 应用: whoami (Helm Chart)

### 测试场景
验证 sslip.io 域名解析方案和 HAProxy 自动路由功能

### 架构说明
```
用户 → sslip.io DNS → HAProxy:23080 → k3d节点LoadBalancer:80 → Traefik → whoami Pod
```

### 修复内容

#### 1. 路由脚本配置文件路径错误 ✅ 已解决
- **问题**: `haproxy_route.sh` 和 `haproxy_sync.sh` 操作 `compose/haproxy/haproxy.cfg`
- **实际**: Bootstrap 使用 `compose/infrastructure/haproxy.cfg`
- **解决**: 修改脚本第6-7行，统一使用 infrastructure 路径

#### 2. K3D 集群端口识别错误 ✅ 已解决
- **问题**: k3d 使用 Traefik LoadBalancer 监听端口 80，但脚本配置为 NodePort 30080
- **影响**: HAProxy 路由失败，返回 "not found"
- **解决**: 修改 `haproxy_route.sh` 第42-65行
  - 检测 k3d 集群容器名 (`k3d-<env>-server-0`)
  - 自动使用端口 80 代替 30080
  - kind 集群保持 NodePort 30080

#### 3. sslip.io 域名解析 ✅ 已验证
- **配置**: `BASE_DOMAIN=192.168.51.30.sslip.io`
- **测试**: `dev-k3d.192.168.51.30.sslip.io` 正确解析到 192.168.51.30
- **优点**: 零配置，无需修改 /etc/hosts

### 测试步骤
1. 清理环境: `./scripts/clean.sh`
2. 启动基础设施: `./scripts/bootstrap.sh`
3. 创建 3 个 k3d 集群:
   ```bash
   ./scripts/create_env.sh -n dev-k3d
   ./scripts/create_env.sh -n uat-k3d
   ./scripts/create_env.sh -n prod-k3d
   ```
4. 修复路由脚本
5. 重新同步路由: `./scripts/haproxy_sync.sh --prune`
6. 部署 whoami 到 dev-k3d:
   ```bash
   helm install whoami cowboysysop/whoami --set ingress.enabled=true \
     --set ingress.hosts[0].host=dev-k3d.192.168.51.30.sslip.io \
     --set ingress.hosts[0].paths[0].path=/ \
     --set ingress.hosts[0].paths[0].pathType=Prefix \
     --kubeconfig ~/.kube/config --kube-context k3d-dev-k3d
   ```

### 验证结果

✅ **HAProxy 配置自动更新**
```haproxy
# Frontend ACL
acl host_dev-k3d  hdr(host) -i dev-k3d.192.168.51.30.sslip.io
use_backend be_dev-k3d if host_dev-k3d

# Backend (自动检测 k3d 使用端口 80)
backend be_dev-k3d
  server s1 10.10.5.2:80
backend be_uat-k3d
  server s1 10.10.6.2:80
backend be_prod-k3d
  server s1 10.10.7.2:80
```

✅ **sslip.io 域名解析**
```bash
curl http://dev-k3d.192.168.51.30.sslip.io:23080/
# 返回 whoami 输出
```

✅ **HAProxy 路由 (使用 Host header)**
```bash
curl -H 'Host: dev-k3d.192.168.51.30.sslip.io' http://192.168.51.30:23080/
# 返回 whoami 输出
Hostname: whoami-78b8b89bf8-2lbgk
IP: 10.42.0.10
...
```

✅ **其他集群路由验证**
```bash
curl -H 'Host: uat-k3d.192.168.51.30.sslip.io' http://192.168.51.30:23080/
# 返回 404 (正常，未部署应用)

curl -H 'Host: prod-k3d.192.168.51.30.sslip.io' http://192.168.51.30:23080/
# 返回 404 (正常，未部署应用)
```

### 关键配置文件变更

**scripts/haproxy_route.sh**
```bash
# 第6-7行: 修复配置文件路径
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
DCMD=(docker compose -f "$ROOT_DIR/compose/infrastructure/docker-compose.yml")

# 第42-65行: 智能检测集群类型和端口
add_backend() {
  local tmp b_begin b_end ip detected_port
  if ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}-control-plane" 2>/dev/null); then
    # kind cluster detected - use NodePort
    detected_port="$node_port"
  elif ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "k3d-${name}-server-0" 2>/dev/null); then
    # k3d cluster detected - use LoadBalancer port 80
    detected_port=80
  else
    ip="127.0.0.1"
    detected_port="$node_port"
  fi
  # ... 使用 detected_port 配置 backend
}
```

**scripts/haproxy_sync.sh**
```bash
# 第6行: 修复配置文件路径
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
```

### 技术要点

1. **K3D vs KIND 端口差异**
   - K3D: Traefik LoadBalancer 监听 80/443
   - KIND: Traefik NodePort 监听 30080/30443

2. **sslip.io 优势**
   - 零配置，无需 DNS 服务器
   - 适合多人协作环境
   - `<env>.192.168.51.30.sslip.io` 自动解析到 `192.168.51.30`

3. **HAProxy 自动配置**
   - 通过 `haproxy_route.sh` 智能检测集群类型
   - 自动选择正确端口 (kind: 30080, k3d: 80)
   - 支持动态 ACL 和 backend 管理

### 总结
✅ **sslip.io 域名解析**: 完全工作
✅ **HAProxy 自动路由**: 完全工作
✅ **K3D 集群支持**: 完全工作
✅ **脚本自动化**: 智能检测集群类型
✅ **零配置体验**: 开箱即用

### 需要的后续工作
- [ ] 在其他集群 (uat-k3d, prod-k3d) 部署示例应用
- [ ] 更新 README 文档说明 k3d vs kind 端口差异
- [ ] 考虑添加 HTTPS 支持 (Let's Encrypt + sslip.io)

---
# Smoke Test @ 2025-10-06 01:17:32
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 10 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 10 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 17 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 19 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 21 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 24 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 33 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 33 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 6 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 3 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (devops.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:17:33
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 10 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 10 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 17 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 19 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 21 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 24 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 33 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 33 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 6 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 3 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (dev.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:17:53
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 10 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 10 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 18 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 19 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 21 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 24 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 34 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 34 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 6 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 3 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (uat.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:18:13
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 10 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 10 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 17 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 18 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 20 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 22 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 24 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 34 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 34 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 6 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 4 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (prod.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:18:33
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 15 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 15 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 17 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 18 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 20 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 22 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 25 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 34 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 34 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 7 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 4 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (dev-k3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:18:53
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 13 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 13 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 15 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 15 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 17 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 19 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 19 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 20 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 22 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 25 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 35 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 35 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 7 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 4 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (uat-k3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:19:14
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 11 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 11 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 13 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 13 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 13 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 13 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 15 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 15 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 18 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 19 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 19 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 21 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 23 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 25 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 35 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 35 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 8 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 5 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (prod-k3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:19:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 13 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 13 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 13 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 13 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 18 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 19 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 19 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 21 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 23 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 26 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 35 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 35 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 8 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 5 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (debug-k3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:19:54
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 13 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 13 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 18 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 20 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 20 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 22 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 23 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 26 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 36 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 36 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 8 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 5 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (test-final.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 01:20:14
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                         IMAGE                                  STATUS
k3d-test-k3d-fixed-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 12 minutes
k3d-test-k3d-fixed-server-0   rancher/k3s:v1.31.5-k3s1               Up 12 minutes
k3d-test-final-serverlb       ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-test-final-server-0       rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-debug-k3d-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-debug-k3d-server-0        rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-prod-k3d-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-prod-k3d-server-0         rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-uat-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 19 minutes
k3d-uat-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 19 minutes
k3d-dev-k3d-serverlb          ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 20 minutes
k3d-dev-k3d-server-0          rancher/k3s:v1.31.5-k3s1               Up 20 minutes
prod-control-plane            kindest/node:v1.31.12                  Up 22 minutes
uat-control-plane             kindest/node:v1.31.12                  Up 24 minutes
dev-control-plane             kindest/node:v1.31.12                  Up 26 minutes
k3d-devops-serverlb           ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 36 minutes
k3d-devops-server-0           rancher/k3s:v1.31.5-k3s1               Up 36 minutes
portainer-ce                  portainer/portainer-ce:2.33.2-alpine   Up 9 minutes
haproxy-gw                    haproxy:3.2.6-alpine3.22               Up 6 minutes
gitlab                        gitlab/gitlab-ce:17.11.7-ce.0          Up 35 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (test-k3d-fixed.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
- 9 testfinal type=7 url=10.10.8.4
- 10 testk3dfixed type=7 url=10.10.9.4
\n---\n
# Smoke Test @ 2025-10-06 09:22:28
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 4 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 4 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 6 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 6 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 7 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 7 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 9 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 11 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 13 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 16 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 3 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 3 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 43 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.devk3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:23:09
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 6 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 7 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 8 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 8 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 9 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 11 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 13 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 17 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 3 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 3 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 43 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:23:50
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 6 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 6 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 7 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 7 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 9 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 9 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 10 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 12 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 14 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 18 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 4 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 4 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 43 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (argocd.devops.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:44:44
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 27 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 27 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 28 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 28 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 29 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 29 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 31 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 33 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 35 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 38 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 38 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up About a minute
haproxy-gw              haproxy:3.2.6-alpine3.22               Up About a minute
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 44 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:44:56
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 27 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 27 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 28 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 28 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 30 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 30 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 31 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 33 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 35 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 39 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 39 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up About a minute
haproxy-gw              haproxy:3.2.6-alpine3.22               Up About a minute
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 44 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:45:06
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 27 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 27 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 28 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 28 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 30 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 30 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 31 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 33 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 35 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 39 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 39 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up About a minute
haproxy-gw              haproxy:3.2.6-alpine3.22               Up About a minute
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 44 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:45:19
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 27 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 27 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 29 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 29 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 30 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 30 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 32 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 33 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 36 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 39 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 39 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 44 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.devk3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:45:30
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 27 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 28 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 29 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 29 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 30 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 30 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 32 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 34 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 36 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 39 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 39 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 44 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.uatk3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:45:41
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 28 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 28 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 29 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 29 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 30 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 30 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 32 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 34 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 36 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 39 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 39 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 44 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.prodk3d.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 09:45:52
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 28 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 28 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 29 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 29 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 31 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 31 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 32 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 34 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 36 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 40 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 40 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 44 hours (healthy)
\n## Curl
\n- Portainer HTTP (23380)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (23343)
  HTTP/1.1 200 OK
\n- Ingress Host (argocd.devops.192.168.51.30.sslip.io via 23080)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 11:46:01
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 14 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 14 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 17 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 19 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 20 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 22 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 24 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 26 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 31 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 31 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 12 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 12 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 46 hours (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 11:46:15
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 15 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 15 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 17 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 17 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 20 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 20 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 22 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 24 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 26 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 31 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 31 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 12 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 12 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 46 hours (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 11:46:28
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 15 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 15 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 18 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 20 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 20 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 22 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 24 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 26 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 31 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 31 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 12 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 12 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 46 hours (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 11:46:47
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 15 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 15 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 18 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 20 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 20 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 22 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 24 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 27 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 31 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 32 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 12 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 12 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 46 hours (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.devk3d.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 11:47:00
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 15 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 15 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 18 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 20 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 20 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 23 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 25 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 27 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 32 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 32 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 13 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 13 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 46 hours (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.uatk3d.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 11:47:12
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 18 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 18 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 21 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 21 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 23 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 25 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 27 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 32 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 32 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 13 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 13 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 46 hours (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.prodk3d.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 11:47:25
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 16 minutes
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 16 minutes
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 19 minutes
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 19 minutes
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 21 minutes
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 21 minutes
prod-control-plane      kindest/node:v1.31.12                  Up 23 minutes
uat-control-plane       kindest/node:v1.31.12                  Up 25 minutes
dev-control-plane       kindest/node:v1.31.12                  Up 27 minutes
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 32 minutes
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 32 minutes
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 13 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 13 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 46 hours (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (argocd.devops.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 16:22:45
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
prod-control-plane      kindest/node:v1.31.12                  Up 5 hours
uat-control-plane       kindest/node:v1.31.12                  Up 5 hours
dev-control-plane       kindest/node:v1.31.12                  Up 5 hours
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 5 hours
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up About a minute
haproxy-gw              haproxy:3.2.6-alpine3.22               Up About a minute
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 2 days (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 16:23:00
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
prod-control-plane      kindest/node:v1.31.12                  Up 5 hours
uat-control-plane       kindest/node:v1.31.12                  Up 5 hours
dev-control-plane       kindest/node:v1.31.12                  Up 5 hours
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 5 hours
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up About a minute
haproxy-gw              haproxy:3.2.6-alpine3.22               Up About a minute
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 2 days (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 16:23:15
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
prod-control-plane      kindest/node:v1.31.12                  Up 5 hours
uat-control-plane       kindest/node:v1.31.12                  Up 5 hours
dev-control-plane       kindest/node:v1.31.12                  Up 5 hours
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 5 hours
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 2 days (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 16:23:29
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
prod-control-plane      kindest/node:v1.31.12                  Up 5 hours
uat-control-plane       kindest/node:v1.31.12                  Up 5 hours
dev-control-plane       kindest/node:v1.31.12                  Up 5 hours
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 5 hours
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 2 days (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.devk3d.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 16:23:44
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
prod-control-plane      kindest/node:v1.31.12                  Up 5 hours
uat-control-plane       kindest/node:v1.31.12                  Up 5 hours
dev-control-plane       kindest/node:v1.31.12                  Up 5 hours
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 5 hours
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 2 days (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.uatk3d.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 16:24:00
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
prod-control-plane      kindest/node:v1.31.12                  Up 5 hours
uat-control-plane       kindest/node:v1.31.12                  Up 5 hours
dev-control-plane       kindest/node:v1.31.12                  Up 5 hours
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 5 hours
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 2 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 2 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 2 days (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (whoami.prodk3d.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n
# Smoke Test @ 2025-10-06 16:24:19
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                   IMAGE                                  STATUS
k3d-prod-k3d-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-prod-k3d-server-0   rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-uat-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-uat-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
k3d-dev-k3d-serverlb    ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-dev-k3d-server-0    rancher/k3s:v1.31.5-k3s1               Up 5 hours
prod-control-plane      kindest/node:v1.31.12                  Up 5 hours
uat-control-plane       kindest/node:v1.31.12                  Up 5 hours
dev-control-plane       kindest/node:v1.31.12                  Up 5 hours
k3d-devops-serverlb     ghcr.io/k3d-io/k3d-proxy:5.8.3         Up 5 hours
k3d-devops-server-0     rancher/k3s:v1.31.5-k3s1               Up 5 hours
portainer-ce            portainer/portainer-ce:2.33.2-alpine   Up 3 minutes
haproxy-gw              haproxy:3.2.6-alpine3.22               Up 3 minutes
gitlab                  gitlab/gitlab-ce:17.11.7-ce.0          Up 2 days (healthy)
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/1.1 200 OK
\n- Ingress Host (argocd.devops.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- 1 dockerhost type=1 url=unix:///var/run/docker.sock
- 2 devops type=7 url=10.10.2.4
- 3 dev type=7 url=172.19.0.3
- 4 uat type=7 url=172.19.0.3
- 5 prod type=7 url=172.19.0.3
- 6 devk3d type=7 url=10.10.5.4
- 7 uatk3d type=7 url=10.10.6.4
- 8 prodk3d type=7 url=10.10.7.4
\n---\n

## GitOps 动态环境管理测试 (2025-10-07)

### 测试目标
验证环境增删改时 ApplicationSet 自动同步功能

### 测试环境
- Base Domain: 192.168.51.30.sslip.io
- ArgoCD: http://argocd.devops.192.168.51.30.sslip.io
- Gitea: http://git.devops.192.168.51.30.sslip.io

### 测试场景1：环境新增

#### 操作步骤
1. 在 config/environments.csv 添加测试环境:
   ```csv
   test-auto,k3d,30080,19007,true,true,38094,38447
   ```

2. 执行环境创建:
   ```bash
   ./scripts/create_env.sh -n test-auto
   ```

#### 验证结果
✅ **环境创建成功**
- k3d 集群创建: `k3d-test-auto` (API Server: 127.0.0.1:38641)
- Portainer Edge Agent 注册: endpoint #4 `testauto`
- HAProxy 路由添加: `*.test-auto.192.168.51.30.sslip.io`
- ArgoCD 集群注册: `cluster-test-auto` secret 创建

✅ **ApplicationSet 自动更新**
- sync_applicationset.sh 自动执行
- whoami-applicationset.yaml 包含 test-auto 条目:
  ```yaml
  - env: test-auto
    branch: main
    clusterName: test-auto
  ```

✅ **Application 自动生成**
- ArgoCD Application 创建: `whoami-test-auto`
- 状态: Unknown (预期,因跨集群连接问题)

### 测试场景2：环境删除

#### 操作步骤
1. 执行环境删除:
   ```bash
   ./scripts/delete_env.sh -n test-auto
   ```

2. 从 config/environments.csv 移除 test-auto 行

3. 重新同步 ApplicationSet:
   ```bash
   ./scripts/sync_applicationset.sh
   ```

#### 验证结果
✅ **环境删除成功**
- k3d 集群删除: `k3d-test-auto` 已删除
- Portainer endpoint 删除: `testauto` (#4) 已移除
- HAProxy 路由删除: test-auto 路由已清除
- ArgoCD 集群注销: `cluster-test-auto` secret 已删除

✅ **ApplicationSet 自动更新**
- whoami-applicationset.yaml 不再包含 test-auto 条目
- 仅保留 9 个环境 (dev, uat, prod, dev-k3d, uat-k3d, prod-k3d, debug-k3d, test-final, test-k3d-fixed)

✅ **Application 自动清理**
- ArgoCD Application `whoami-test-auto` 已自动删除
- 剩余 Application: whoami-dev

### 已知问题

#### 1. 跨集群访问限制
**问题描述**: ArgoCD (devops 集群) 无法访问业务集群 API Server

**根本原因**:
- argocd_register_kubectl.sh 从 kubectl config 读取 API Server 地址
- 该地址为 `127.0.0.1:<port>`,从 devops 集群 Pod 内无法访问
- k3d 集群间网络隔离 (不同 docker 网络)

**影响范围**:
- 所有非 devops 的业务集群 (kind/k3d) 无法被 ArgoCD 同步
- whoami 应用无法部署到业务集群

**临时方案**:
- 当前 ApplicationSet 配置正确,但 Application 状态为 Unknown/ComparisonError
- 需要解决集群间网络连通性

**可能解决方案**:
1. 使用 Docker 容器网络互联 (docker network connect)
2. 修改 argocd_register_kubectl.sh,将 API Server 地址改为容器 IP
3. 使用 HAProxy 代理 Kubernetes API Server
4. 考虑使用 External Secrets/Config Management 替代跨集群部署

#### 2. delete_env.sh 不自动清理 CSV
**问题描述**: delete_env.sh 只删除集群,不从 environments.csv 移除配置

**影响**: 需要手动编辑 CSV 并重新运行 sync_applicationset.sh

**建议**: 将 CSV 清理集成到 delete_env.sh 脚本中

### 测试结论

✅ **动态环境管理功能正常**:
- 环境新增: ApplicationSet 自动生成新环境的 Application
- 环境删除: ApplicationSet 自动清理已删除环境的 Application
- CSV 驱动配置: 无硬编码,完全由 environments.csv 控制

⚠️ **需要解决跨集群访问问题才能实现完整 GitOps 流程**

### 下一步行动
1. 解决 ArgoCD 跨集群访问限制
2. 优化 delete_env.sh 自动清理 CSV 配置
3. 补充端到端测试 (Git push → ArgoCD sync → 应用部署)

---
