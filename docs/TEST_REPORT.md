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
