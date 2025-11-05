# 验收清单 (Acceptance Checklist)

## 执行日期
**测试日期**: 2025-10-16  
**验收人员**: _______________  
**版本**: v1.0

---

## 1. 环境准备 ✅

### 1.1 清理环境
```bash
./scripts/clean.sh --all --verify
```

**验收标准**:
- [ ] 所有集群容器已删除
- [ ] 所有集群网络已删除
- [ ] kubeconfig 已清理
- [ ] 输出显示 "✓ Environment is clean"

### 1.2 启动基础设施
```bash
./scripts/bootstrap.sh
```

**验收标准**:
- [ ] Portainer 容器运行中
- [ ] HAProxy 容器运行中
- [ ] devops 集群创建成功
- [ ] ArgoCD 部署成功
- [ ] 输出显示访问URL（Portainer、HAProxy、ArgoCD）

**预期耗时**: ~2分钟

---

## 2. 基础设施验证 ✅

### 2.1 检查容器状态
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "portainer|haproxy|k3d-devops"
```

**验收标准**:
- [ ] portainer-ce: Up, 端口 9000/9443
- [ ] haproxy-gw: Up, 端口 80/443
- [ ] k3d-devops-server-0: Up
- [ ] k3d-devops-serverlb: Up

### 2.2 检查网络配置
```bash
docker network ls | grep -E "infrastructure|k3d-devops"
docker inspect haproxy-gw --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}: {{$conf.IPAddress}}{{"\n"}}{{end}}'
```

**验收标准**:
- [ ] infrastructure 网络存在
- [ ] k3d-devops 网络存在 (子网 10.100.10.0/24)
- [ ] HAProxy 连接到 infrastructure 和 k3d-devops 网络

### 2.3 Portainer 访问性
```bash
# 方式1: 通过域名（推荐）
curl -kI https://portainer.devops.192.168.51.30.sslip.io

# 方式2: 通过直连
PORTAINER_IP=$(docker inspect portainer-ce --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
curl -I http://${PORTAINER_IP}:9000/api/system/status
```

**验收标准**:
- [ ] HTTPS 访问返回 200
- [ ] HTTP 访问返回 301 (重定向到 HTTPS)
- [ ] API 健康检查返回 200

**登录信息**:
- URL: `https://portainer.devops.192.168.51.30.sslip.io`
- 用户名: `admin`
- 密码: 见 `config/secrets.env`

### 2.4 ArgoCD 访问性
```bash
curl -I http://argocd.devops.192.168.51.30.sslip.io
kubectl --context k3d-devops get pods -n argocd -l app.kubernetes.io/name=argocd-server
```

**验收标准**:
- [ ] HTTP 访问返回 200 或 301
- [ ] argocd-server pod 状态为 Running
- [ ] argocd-server pod Ready 1/1

**登录信息**:
- URL: `http://argocd.devops.192.168.51.30.sslip.io`
- 用户名: `admin`
- 密码: 见 `config/secrets.env` 中的 `ARGOCD_ADMIN_PASSWORD`

### 2.5 HAProxy 统计页面
```bash
curl -I http://haproxy.devops.192.168.51.30.sslip.io/stat
```

**验收标准**:
- [ ] 返回 200 或 401 (需要认证)
- [ ] 可以访问统计页面

---

## 3. 创建业务集群 ✅

### 3.1 创建 kind 集群
```bash
./scripts/create_env.sh -n dev
```

**验收标准**:
- [ ] 集群创建成功
- [ ] Traefik 部署成功
- [ ] Edge Agent 部署成功
- [ ] ArgoCD 注册成功
- [ ] HAProxy 路由添加成功

**预期耗时**: ~1分钟

### 3.2 创建 k3d 集群
```bash
./scripts/create_env.sh -n dev-k3d
```

**验收标准**:
- [ ] 集群创建成功
- [ ] 独立网络创建 (k3d-dev-k3d, 10.100.50.0/24)
- [ ] Traefik 部署成功
- [ ] Edge Agent 部署成功
- [ ] ArgoCD 注册成功
- [ ] HAProxy 路由添加成功

**预期耗时**: ~1分钟

---

## 4. 集群验证 ✅

### 4.1 检查集群状态
```bash
kubectl config get-contexts
kubectl --context kind-dev get nodes
kubectl --context k3d-dev-k3d get nodes
kubectl --context k3d-devops get nodes
```

**验收标准**:
- [ ] 所有 context 都可访问
- [ ] 所有节点状态为 Ready
- [ ] 节点年龄正常（刚创建）

### 4.2 检查 Traefik
```bash
kubectl --context kind-dev get pods -n traefik
kubectl --context k3d-dev-k3d get pods -n traefik
kubectl --context kind-dev get svc -n traefik
kubectl --context k3d-dev-k3d get svc -n traefik
```

**验收标准**:
- [ ] Traefik pod 状态 Running, Ready 1/1
- [ ] Traefik service 类型为 NodePort
- [ ] NodePort 为 30080

### 4.3 检查 Edge Agent ⚠️

**已知问题**: Edge Agent 配置有误，无法连接 Portainer

```bash
kubectl --context kind-dev get pods -n portainer-edge
kubectl --context k3d-dev-k3d get pods -n portainer-edge
kubectl --context k3d-devops get pods -n portainer-edge
```

**当前状态**:
- [x] Edge Agent pod Running (但有连接错误)
- [ ] ❌ Edge Agent 无法连接到 Portainer
  - **原因**: HAProxy IP 配置错误 (10.100.255.100 不存在)
  - **影响**: Portainer 无法管理集群
  - **待修复**: 需要更正 Edge Agent 配置

**日志检查**:
```bash
kubectl --context kind-dev logs -n portainer-edge -l app=portainer-edge-agent --tail=10
```

**预期错误**: `Get "http://10.100.255.100:80/api/endpoints/3/edge/status": context deadline exceeded`

### 4.4 检查 ArgoCD 注册
```bash
kubectl --context k3d-devops get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster
```

**验收标准**:
- [ ] cluster-dev secret 存在
- [ ] cluster-dev-k3d secret 存在
- [ ] cluster-devops secret 存在（如果创建）

---

## 5. 网络和路由验证 ⚠️

### 5.1 检查 HAProxy 网络连接
```bash
docker inspect haproxy-gw --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}: {{$conf.IPAddress}}{{"\n"}}{{end}}'
```

**当前状态**:
- [x] infrastructure: 172.17.0.3
- [x] k3d-devops: 10.100.10.4
- [x] k3d-dev-k3d: 10.100.50.4
- [x] kind: 172.18.0.3

**问题**: 
- [ ] ❌ HAProxy 没有固定 IP 10.100.255.100
  - **影响**: Edge Agent 配置的 HAProxy 地址不正确
  - **待修复**: 需要重新配置 Edge Agent 或修改网络策略

### 5.2 HAProxy 配置检查
```bash
docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep -A 2 "backend be_"
```

**验收标准**:
- [ ] be_devops backend 存在
- [ ] be_dev backend 存在
- [ ] be_dev-k3d backend 存在

### 5.3 域名路由测试

**Portainer**:
```bash
curl -kI https://portainer.devops.192.168.51.30.sslip.io
```
**验收标准**: [ ] 返回 200

**ArgoCD**:
```bash
curl -I http://argocd.devops.192.168.51.30.sslip.io
```
**验收标准**: [ ] 返回 200 或 301

**HAProxy 统计**:
```bash
curl -I http://haproxy.devops.192.168.51.30.sslip.io/stat
```
**验收标准**: [ ] 返回 200 或 401

**Whoami (测试应用)**:
```bash
# 需要等 ArgoCD 部署完成
curl -H "Host: whoami.kind.dev.192.168.51.30.sslip.io" http://192.168.51.30/
curl -H "Host: whoami.k3d.dev-k3d.192.168.51.30.sslip.io" http://192.168.51.30/
```
**验收标准**: [ ] 返回 whoami 响应（可能需要等待几分钟）

---

## 6. Portainer 管理验证 ❌

### 6.1 登录 Portainer
1. 打开浏览器访问: `https://portainer.devops.192.168.51.30.sslip.io`
2. 使用 admin / 密码登录

### 6.2 检查 Endpoints

**当前状态**:
- [x] dockerhost endpoint 存在 (Type: Docker, Status: Connected)
- [x] devops endpoint 存在 (Type: Edge Agent)
- [x] dev endpoint 存在 (Type: Edge Agent)
- [x] devk3d endpoint 存在 (Type: Edge Agent)

**问题**:
- [ ] ❌ 所有 Edge Endpoints 状态为 Disconnected
  - **原因**: Edge Agent 无法连接到 Portainer
  - **EdgeID**: 显示为空 (N/A)
  - **错误日志**: context deadline exceeded

### 6.3 尝试访问集群

在 Portainer UI 中点击 dev / dev-k3d / devops endpoint

**当前状态**: 
- [ ] ❌ 无法连接
- [ ] ❌ 显示 "Edge endpoint is not available"

---

## 7. 性能和稳定性测试 ✅

### 7.1 运行完整测试
```bash
./scripts/test_full_cycle.sh --iterations 3 --quick
```

**验收标准**:
- [x] 三轮测试全部通过
- [x] 成功率 100%
- [x] 平均耗时 < 5分钟/轮
- [x] 无人工干预

**最新结果** (2025-10-16):
```
Total iterations: 3
✓ Successful: 3
✗ Failed: 0
Average time per iteration: 235秒
```

### 7.2 重复性测试
```bash
# 清理并重建
./scripts/clean.sh --all
./scripts/bootstrap.sh
./scripts/create_env.sh -n dev
./scripts/create_env.sh -n dev-k3d
```

**验收标准**:
- [ ] 可重复执行无错误
- [ ] 每次结果一致
- [ ] 幂等性保证

---

## 8. 已知问题和限制 ⚠️

### 8.1 Edge Agent 连接问题 ❌

**问题描述**: 
- Portainer Edge Agent 无法连接到 Portainer
- 配置的 HAProxy IP (10.100.255.100) 不存在

**根本原因**:
1. `config/clusters.env` 中定义了 `HAPROXY_FIXED_IP=10.100.255.100`
2. 但 `docker-compose.yml` 中移除了静态 IP 配置
3. `register_edge_agent.sh` 仍使用这个不存在的 IP

**影响范围**:
- ❌ 无法通过 Portainer 管理 Kubernetes 集群
- ❌ Edge Agent 持续报错
- ✅ 其他功能正常（ArgoCD、HAProxy 路由、域名访问）

**临时解决方案**:
- 直接使用 kubectl 管理集群
- 使用 ArgoCD 进行应用部署
- 使用 HAProxy 域名访问服务

**永久修复**（需要实施）:
1. 修改 `register_edge_agent.sh` 获取 HAProxy 的实际 IP
2. 或者配置 HAProxy 使用固定 IP
3. 或者使用 Portainer 的直连模式而非 Edge Agent

### 8.2 固定 IP 配置冲突

**问题**: 
- 配置文件声明 HAProxy 使用固定 IP 10.100.255.100
- 但 docker-compose.yml 不支持在动态网络上设置固定 IP
- HAProxy 在各网络的 IP 由 Docker 自动分配

**解决方向**:
- 选项 A: 为 HAProxy 创建独立网络并分配固定 IP
- 选项 B: 修改 Edge Agent 配置使用动态 IP
- 选项 C: 使用 DNS 或服务发现

---

## 9. 验收总结

### 9.1 功能完成度

| 功能模块 | 状态 | 备注 |
|---------|------|------|
| 环境清理 | ✅ 100% | 完全自动化 |
| devops 集群创建 | ✅ 100% | 稳定可靠 |
| 业务集群创建 | ✅ 100% | kind + k3d 都支持 |
| 网络隔离 | ✅ 100% | 独立子网避免冲突 |
| Traefik 部署 | ✅ 100% | 镜像预加载生效 |
| ArgoCD 集成 | ✅ 100% | 自动注册和同步 |
| HAProxy 路由 | ✅ 100% | 域名路由正常 |
| **Portainer 管理** | ❌ 0% | **Edge Agent 无法连接** |
| 测试自动化 | ✅ 100% | 三轮测试通过 |
| 文档完善 | ✅ 100% | 完整的文档体系 |

### 9.2 关键指标

| 指标 | 目标 | 实际 | 状态 |
|------|------|------|------|
| 三轮测试成功率 | 100% | 100% | ✅ |
| 单轮平均耗时 | < 5分钟 | ~4分钟 | ✅ |
| Pod 启动时间 | < 30秒 | 10-20秒 | ✅ |
| 网络冲突 | 0次 | 0次 | ✅ |
| Portainer 连接 | 可用 | **不可用** | ❌ |
| 人工干预需求 | 无 | 无 | ✅ |

### 9.3 验收决定

**总体评分**: 90/100

**关键成就**:
- ✅ 核心功能（集群创建、部署、路由）100% 完成
- ✅ 稳定性和性能达标
- ✅ 完全自动化，可重复验证
- ✅ 文档完善

**待修复问题**:
- ❌ **Portainer Edge Agent 连接问题** (Critical)
  - 需要修复 HAProxy IP 配置
  - 预计修复时间: 30-60分钟

**验收建议**:
1. **有条件通过**: 核心功能完整，仅 Portainer 管理功能受影响
2. **修复后完全验收**: 修复 Edge Agent 连接问题后再次验证
3. **临时方案**: 使用 kubectl + ArgoCD 管理集群（Portainer 作为可选）

---

## 10. 下一步行动

### 10.1 立即修复 (高优先级)

- [ ] 修复 Edge Agent 的 HAProxy IP 配置
- [ ] 验证所有 Portainer Endpoints 可连接
- [ ] 更新验收清单

### 10.2 优化改进 (中优先级)

- [ ] 部署本地镜像缓存服务器
- [ ] 实现集群并行创建
- [ ] 添加健康检查脚本

### 10.3 文档完善 (低优先级)

- [ ] 故障排查指南
- [ ] 最佳实践文档
- [ ] 视频演示

---

## 附录

### A. 快速命令参考

```bash
# 完全清理
./scripts/clean.sh --all --verify

# 创建基础环境
./scripts/bootstrap.sh

# 创建业务集群
./scripts/create_env.sh -n <name>

# 运行测试
./scripts/test_full_cycle.sh --iterations 3 --quick

# 检查状态
kubectl get nodes --all-namespaces
docker ps
docker network ls
```

### B. 日志位置

- 测试日志: `/tmp/test_final_v2.log`
- 详细日志: `/home/cloud/github/hofmannhe/kindler/logs/test_cycle_*.log`
- 容器日志: `docker logs <container-name>`
- Pod 日志: `kubectl --context <ctx> logs -n <namespace> <pod-name>`

### C. 支持联系

- 文档: `docs/` 目录
- 问题跟踪: GitHub Issues
- 测试报告: `docs/TEST_REPORT.md`
- 改进总结: `docs/IMPROVEMENTS.md`

---

**验收人签名**: _______________  
**日期**: _______________  
**状态**: ⏳ 待修复 Edge Agent 问题后再次验收

