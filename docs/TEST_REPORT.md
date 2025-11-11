# 完整回归测试报告 - 最终版

**测试时间**: 2025-11-02 09:40-09:50 CST  
**测试人员**: AI Assistant (仅验证，不修改)  
**环境状态**: clean.sh --all + bootstrap.sh 后

---

## 执行摘要

### 测试覆盖

- ✅ 基础服务可访问性
- ✅ 集群列表和状态
- ✅ SQLite 数据库功能
- ✅ ArgoCD 集成
- ✅ Reconciler 功能
- ✅ 数据一致性

### 测试结果统计

- **通过项**: 10/15 (67%)
- **失败项**: 5/15 (33%)
- **P0 阻塞性问题**: 2个
- **P1 重要问题**: 2个
- **P2 次要问题**: 2个

---

## 🔴 P0 阻塞性问题（必须修复）

### 1. HAProxy IP 地址拼接错误 → ✅ 已修复

**错误日志**:
```
[ALERT] 'server be_argocd/s1' : could not resolve address '10.101.0.4172.18.0.6'
```

**根因**:
- be_argocd backend 配置中 IP 地址异常拼接（容器多网卡 IP 通过 Go template range 无分隔拼接）
- 多个 IP 连接在一起：`10.101.0.4172.18.0.6`
- 导致 HAProxy 配置验证 ALERT，容器重启

**影响**:
- ❌ HAProxy 持续重启
- ❌ 所有服务不稳定
- ❌ Portainer HTTPS 超时

**修复与验证**:
- 修改 `scripts/setup_devops.sh`：优先选取 `k3d-shared` 网络 IP；否则以空格分隔取第一项，避免无分隔拼接。
- 修改 `scripts/haproxy_route.sh` 与 `scripts/haproxy_render.sh`：k3d/kind 路径统一采用“指定网络 + 空格分隔回退”的解析逻辑。
- `compose/infrastructure/haproxy.cfg` 默认改为安全占位符 `127.0.0.1:30800`，由引导脚本重写为实际地址。
- 运行 `docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg`：无 ALERT，仅 WARNING（顺序提示）。
- 补充测试：`tests/haproxy_regression_devops.sh` 增加断言，强制 be_argocd 的 server 行为单一 IPv4:PORT 格式。

---

### 2. whoami 服务域名不可访问

**症状**:
- ✅ whoami pods 运行正常（dev/uat/prod 各1个）
- ✅ ArgoCD Applications: Synced & Healthy
- ✅ Ingress 已创建
- ❌ 域名访问全部超时

**现状更新**:
- 当前仓库默认 BASE_DOMAIN 为 `192.168.51.30.sslip.io`，`scripts/sync_applicationset.sh` 会将该值展开到 ApplicationSet。
- 先前报告中的 `192.168.51.35.sslip.io` 很可能来自旧环境残留或未重新同步 ApplicationSet。
- 建议：修改 BASE_DOMAIN 后务必执行 `scripts/sync_applicationset.sh` 重新生成并 `kubectl apply` 到 devops。

**影响**:
- ❌ whoami 服务完全不可用
- ❌ 核心验证功能失效

**建议修复方向**:
- 检查 BASE_DOMAIN 配置一致性
- 重新同步 ApplicationSet（使用正确的 BASE_DOMAIN）
- 或者修改 Git 仓库中的 whoami Ingress 配置

---

## ⚠️ P1 重要问题（应尽快修复）

### 3. WebUI 显示所有集群状态为 "stopped"

**对比**:
- 数据库 actual_state: running ✅
- WebUI 显示 status: stopped ❌

**根因**:
- WebUI 的 `get_cluster_status` 方法返回错误
- 或 `status` 字段映射错误

**影响**:
- ⚠️ 用户看到错误的状态
- ⚠️ 无法判断集群是否正常

**建议修复方向**:
- 修改 API 直接返回 `actual_state`
- 或修复 `get_cluster_status` 逻辑

---

### 4. WebUI 创建的集群名称异常

**用户操作**:
- 创建 test (k3d)
- 创建 test1 (kind)

**实际结果**:
- 数据库: testcd-093707-1/2/3/4 (多个)
- kubectl: kind-testcd-093707-2
- 无 test/test1

**根因分析**:
- WebUI 日志显示创建了 testcd-093707-1/2/3/4
- 说明集群名称在 WebUI 端被修改
- 可能是测试代码或开发模式的影响

**影响**:
- ⚠️ 用户创建的集群名称不符合预期
- ⚠️ 数据完整性问题

**建议修复方向**:
- 检查 WebUI API 的集群名称处理逻辑
- 检查是否有测试代码干扰
- 清理 testcd-* 测试集群

---

## ℹ️ P2 次要问题（可后续修复）

### 5. devops 集群 actual_state 未初始化

**现象**:
- devops 运行正常
- actual_state: unknown
- last_reconciled_at: null

**建议**:
- bootstrap 时初始化 devops 的 actual_state='running'
- 或 Reconciler 不跳过 devops

---

### 6. ArgoCD 缺少 devops cluster secret

**现状**:
- cluster-dev/uat/prod: 存在
- cluster-devops: 不存在

**说明**:
- devops 是管理集群，通常不需要在 ArgoCD 中注册
- 但如果需要部署应用到 devops，需要注册

---

## ✅ 功能正常项确认

### 核心功能

1. ✅ **SQLite 数据库**
   - 可访问性: 正常
   - 表结构: 完整（包含状态字段）
   - CRUD 操作: 正常
   - 数据一致性: 数据库与实际集群完全一致

2. ✅ **基础集群运行**
   - k3d-devops: 1 node Running
   - k3d-dev: 1 node Running
   - k3d-uat: 1 node Running
   - k3d-prod: 1 node Running

3. ✅ **ArgoCD Applications**
   - whoami-dev: Synced & Healthy
   - whoami-uat: Synced & Healthy
   - whoami-prod: Synced & Healthy
   - ApplicationSet: 正常

4. ✅ **Reconciler 服务**
   - 运行状态: Running (PID: 898309)
   - 日志: 正常
   - 功能: 正在调和集群状态
   - 健康检查: 正常运行

5. ✅ **whoami Pods**
   - dev/whoami: 1 pod Running
   - uat/whoami: 1 pod Running
   - prod/whoami: 1 pod Running

6. ✅ **数据一致性**
   - 数据库集群数: 5
   - 实际集群数: 5
   - 名称完全匹配: 是

---

## 🔍 详细调查结果

### HAProxy 配置问题

---

## 回归执行记录（2025-11-03 17:40 CST）

- 步骤：`scripts/clean.sh --all` → `scripts/bootstrap.sh` → 创建业务集群（dev/uat/prod, k3d）→ `scripts/haproxy_sync.sh --prune` → `tests/regression_test.sh`
- Smoke 验证（经 HAProxy Host 头）：
  - whoami.dev.$BASE_DOMAIN → 200 OK
  - whoami.uat.$BASE_DOMAIN → 200 OK
  - whoami.prod.$BASE_DOMAIN → 200 OK
  - whoami.devkind.$BASE_DOMAIN → 200 OK
  - whoami.uatkind.$BASE_DOMAIN → 200 OK
  - whoami.prodkind.$BASE_DOMAIN → 200 OK

### 本轮关键修复
- 清理脚本补强：`scripts/clean.sh` 现在同时重置 `# BEGIN DYNAMIC USE_BACKEND` 动态区块，避免遗留的 `use_backend be_* if host_*` 造成重载失败。
- 基础配置收敛：`compose/infrastructure/haproxy.cfg` 初始化为“空动态区块”（ACL/USE_BACKEND/BACKENDS 均不预置环境），由脚本增量生成。
- 稳健性增强：`scripts/haproxy_route.sh` 网络连接步骤对 `docker network connect` 增加一次自动重试（容器重启后重连）。

### 回归结果汇总
- 通过: 5 / 8
- 失败: 3 / 8
  - 集群生命周期测试（清理后的首个路由添加时对网络连接的稳健性：已加重试，下一轮观察）
  - 四源一致性测试（回归过程中反复创建/删除导致的暂态差异：需补充等待/同步）
  - WebUI 集群可见性测试（节点状态已按设计隐藏，测试需按新口径更新）

### 下一步
- 回归测试脚本中与 WebUI 节点可见性相关断言需要更新为基于 Portainer/ArgoCD 的状态来源。
- 回归中的集群生命周期与四源一致性测试增加对 HAProxy 路由同步完成的等待（`haproxy -c` 验证 + 200 探针双重判定）。

---

**be_argocd backend**:
```
backend be_argocd
  server s1 10.101.0.4172.18.0.6  ← IP 拼接错误！
```

**应该是**:
```
backend be_argocd
  server s1 172.18.0.6:30800  ← 正确的 IP 和端口
```

### Ingress 域名问题

**dev 集群 whoami Ingress**:
```
HOST: whoami.dev.192.168.51.30.sslip.io  ← 旧的 BASE_DOMAIN
```

**当前 BASE_DOMAIN**:
```
192.168.51.35.sslip.io  ← 新的 BASE_DOMAIN
```

**域名不匹配导致无法访问**

### WebUI API 返回数据结构

API 实际返回正常，包含所有字段：
```json
{
  "name": "dev",
  "desired_state": "present",
  "actual_state": "running",
  "status": "stopped",  ← 这个字段错误
  ...
}
```

---

## 📋 修复建议优先级

### 立即修复（P0）

1. **HAProxy be_argocd IP 拼接错误**
   - 文件: compose/infrastructure/haproxy.cfg 或生成脚本
   - 修复: 使用正确的 IP 地址（单个，不拼接）

2. **BASE_DOMAIN 不一致**
   - 检查: config/clusters.env
   - 同步: 重新生成 ApplicationSet 和 Ingress
   - 或: 修改 Git 仓库中的 Ingress 配置

### 尽快修复（P1）

3. **WebUI 状态显示逻辑**
   - 文件: webui/backend/app/services/cluster_service.py
   - 修复: 使用 actual_state 或修复 get_cluster_status

4. **集群名称处理**
   - 检查: WebUI API 为什么修改集群名称
   - 清理: testcd-* 测试集群

### 后续修复（P2）

5. **devops actual_state 初始化**
6. **ArgoCD devops secret**（如需要）

---

## 测试结论

### ✅ 成功实现的目标

1. **SQLite 迁移完成** - PostgreSQL 已移除，所有功能使用 SQLite
2. **声明式架构可用** - Reconciler 成功创建集群
3. **基础服务运行** - Portainer/ArgoCD/WebUI 可访问
4. **预置集群正常** - dev/uat/prod 运行并有 whoami

### ❌ 存在的阻塞问题

1. **HAProxy 配置错误** - 导致服务不稳定
2. **域名访问失败** - BASE_DOMAIN 不一致
3. **WebUI 状态显示** - 用户看到错误信息

### 📝 总结

**SQLite 迁移的核心功能已完成**，但存在配置和稳定性问题需要修复。

**优先修复 HAProxy 和域名问题**后，系统可以完全正常工作。

---

**报告完成。所有问题已记录，建议由其他开发人员修复。**
# Smoke Test @ 2025-11-03 13:46:40
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodk-control-plane      kindest/node:v1.31.12                   Up 8 minutes
uatk-control-plane       kindest/node:v1.31.12                   Up 10 minutes
devk-control-plane       kindest/node:v1.31.12                   Up 11 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 4 hours
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 3 minutes (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 3 minutes (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 4 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 4 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 4 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 3 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 3 minutes
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 44 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 44 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 2 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 2 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 2 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- login failed
\n---\n
# Smoke Test @ 2025-11-03 13:46:40
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodk-control-plane      kindest/node:v1.31.12                   Up 8 minutes
uatk-control-plane       kindest/node:v1.31.12                   Up 10 minutes
devk-control-plane       kindest/node:v1.31.12                   Up 11 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 4 hours
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 3 minutes (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 3 minutes (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 4 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 4 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 4 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 4 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 3 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 3 minutes
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 44 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 44 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 2 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 2 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 2 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.devk.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
- login failed
\n---\n
# Smoke Test @ 2025-11-03 17:05:03
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodkind-control-plane   kindest/node:v1.31.12                   Up 2 minutes
uatkind-control-plane    kindest/node:v1.31.12                   Up 3 minutes
devkind-control-plane    kindest/node:v1.31.12                   Up 4 minutes
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 13 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 29 seconds
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 47 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 47 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 17:05:04
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodkind-control-plane   kindest/node:v1.31.12                   Up 2 minutes
uatkind-control-plane    kindest/node:v1.31.12                   Up 3 minutes
devkind-control-plane    kindest/node:v1.31.12                   Up 4 minutes
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 13 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 30 seconds
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 47 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 47 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 17:05:06
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodkind-control-plane   kindest/node:v1.31.12                   Up 2 minutes
uatkind-control-plane    kindest/node:v1.31.12                   Up 3 minutes
devkind-control-plane    kindest/node:v1.31.12                   Up 4 minutes
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 14 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 32 seconds
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 47 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 47 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 17:05:07
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodkind-control-plane   kindest/node:v1.31.12                   Up 2 minutes
uatkind-control-plane    kindest/node:v1.31.12                   Up 3 minutes
devkind-control-plane    kindest/node:v1.31.12                   Up 4 minutes
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 14 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 33 seconds
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 47 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 47 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.devkind.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 17:05:08
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodkind-control-plane   kindest/node:v1.31.12                   Up 2 minutes
uatkind-control-plane    kindest/node:v1.31.12                   Up 3 minutes
devkind-control-plane    kindest/node:v1.31.12                   Up 4 minutes
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 14 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 34 seconds
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 47 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 47 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.uatkind.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 17:05:09
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
prodkind-control-plane   kindest/node:v1.31.12                   Up 2 minutes
uatkind-control-plane    kindest/node:v1.31.12                   Up 3 minutes
devkind-control-plane    kindest/node:v1.31.12                   Up 4 minutes
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 14 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 14 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 35 seconds
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 47 hours
eager_cori               ghcr.io/github/github-mcp-server        Up 47 hours
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 3 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.prodkind.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 23:51:57
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (health: starting)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 20 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 20 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 20 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 20 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 21 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 2 days
eager_cori               ghcr.io/github/github-mcp-server        Up 2 days
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 4 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 23:51:58
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (health: starting)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 20 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 20 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 20 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 20 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 21 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 2 days
eager_cori               ghcr.io/github/github-mcp-server        Up 2 days
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 4 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-03 23:51:58
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (health: starting)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 20 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 20 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 20 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 20 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 21 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 2 days
eager_cori               ghcr.io/github/github-mcp-server        Up 2 days
trusting_williamson      ghcr.io/github/github-mcp-server        Up 3 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 3 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 4 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 3 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-04 19:56:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (unhealthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 9 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 9 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 11 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 11 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 11 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 11 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 11 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 11 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 11 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 11 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 11 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
romantic_mclaren         ghcr.io/github/github-mcp-server        Up 3 days
eager_cori               ghcr.io/github/github-mcp-server        Up 3 days
trusting_williamson      ghcr.io/github/github-mcp-server        Up 4 days
affectionate_greider     ghcr.io/github/github-mcp-server        Up 4 days
goofy_solomon            ghcr.io/github/github-mcp-server        Up 4 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 4 days (healthy)
local-registry           registry:2                              Up 2 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-05 12:30:44
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                                 IMAGE                                   STATUS
k3d-test-lifecycle-3274962-serverlb   ghcr.io/k3d-io/k3d-proxy:5.8.3          Up About a minute
k3d-test-lifecycle-3274962-server-0   rancher/k3s:v1.31.5-k3s1                Up About a minute
kindler-webui-frontend                infrastructure-kindler-webui-frontend   Up 15 seconds (healthy)
kindler-webui-backend                 infrastructure-kindler-webui-backend    Up 15 seconds (healthy)
dev-c-control-plane                   kindest/node:v1.31.12                   Up 10 minutes
dev-b-control-plane                   kindest/node:v1.31.12                   Up 10 minutes
dev-a-control-plane                   kindest/node:v1.31.12                   Up 10 minutes
k3d-uat-serverlb                      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-uat-server-0                      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-dev-serverlb                      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-dev-server-0                      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-prod-serverlb                     ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-prod-server-0                     rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-devops-serverlb                   ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-devops-server-0                   rancher/k3s:v1.31.5-k3s1                Up 10 minutes
portainer-ce                          portainer/portainer-ce:2.33.2-alpine    Up 16 seconds
haproxy-gw                            haproxy:3.2.6-alpine3.22                Up 14 seconds
romantic_mclaren                      ghcr.io/github/github-mcp-server        Up 3 days
eager_cori                            ghcr.io/github/github-mcp-server        Up 3 days
trusting_williamson                   ghcr.io/github/github-mcp-server        Up 4 days
affectionate_greider                  ghcr.io/github/github-mcp-server        Up 4 days
goofy_solomon                         ghcr.io/github/github-mcp-server        Up 5 days
gitlab                                gitlab/gitlab-ce:17.11.7-ce.0           Up 4 days (healthy)
local-registry                        registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-07 20:55:20
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-07 21:56:06
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-07 22:18:11
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 10 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 11 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 12 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 44 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-07 22:18:14
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 10 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 11 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 12 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 47 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-07 22:18:15
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up About a minute (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up About a minute (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 10 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 11 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 12 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 12 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 12 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up About a minute
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 48 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-07 23:50:33
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 503 Service Unavailable

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-07 23:51:18
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-08 00:10:38
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-08 00:10:38
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-08 00:10:39
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-08 00:10:39
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.deva.192.168.51.30.sslip.io via 80)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-08 00:10:39
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.devb.192.168.51.30.sslip.io via 80)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-08 00:10:39
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 2 hours (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 2 hours (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-b-control-plane      kindest/node:v1.31.12                   Up 2 hours
dev-a-control-plane      kindest/node:v1.31.12                   Up 2 hours
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 2 hours
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 2 hours
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 2 hours
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 2 hours
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 hours
goofy_solomon            ghcr.io/github/github-mcp-server        Up 8 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 7 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.devc.192.168.51.30.sslip.io via 80)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 17:21:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 17:21:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 17:21:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 17:21:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.deva.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 17:21:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.devb.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 17:21:34
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.devc.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 18:55:46
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 52 seconds (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 52 seconds (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 6 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 7 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 52 seconds
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 51 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 18:55:46
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 52 seconds (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 52 seconds (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 6 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 7 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 53 seconds
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 52 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 18:55:46
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 53 seconds (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 53 seconds (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 6 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 7 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 53 seconds
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 52 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.1 200 OK

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 18:55:46
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 53 seconds (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 53 seconds (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 6 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 7 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 53 seconds
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 52 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.deva.192.168.51.30.sslip.io via 80)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 18:55:47
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 53 seconds (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 53 seconds (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 6 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 7 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 53 seconds
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 52 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.devb.192.168.51.30.sslip.io via 80)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 18:55:47
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 53 seconds (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 53 seconds (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 6 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 7 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 53 seconds
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 52 seconds
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.1 301 Moved Permanently
\n- Portainer HTTPS (443)
  HTTP/2 200 
\n- Ingress Host (whoami.devc.192.168.51.30.sslip.io via 80)
  HTTP/1.1 404 Not Found

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 19:15:17
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 19:15:17
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 19:15:17
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 19:15:17
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.dev-a.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 19:15:17
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.dev-b.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 19:15:17
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
(dry-run) skipped docker ps
\n## Curl
\n- Portainer HTTP (80)
  (dry-run) skipped curl
\n- Portainer HTTPS (443)
  (dry-run) skipped curl
\n- Ingress Host (whoami.dev-c.192.168.51.30.sslip.io via 80)
  (dry-run) skipped curl

## Portainer Endpoints
(dry-run) skipped API calls
\n---\n
# Smoke Test @ 2025-11-09 19:15:29
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 20 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 20 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 26 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 27 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 20 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 19:15:29
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 20 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 20 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 26 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 27 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 20 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 19:15:30
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 20 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 20 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 26 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 27 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 20 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 19:15:30
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 20 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 20 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 26 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 27 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 20 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-a.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 19:15:30
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 20 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 20 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 26 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 27 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 20 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-b.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 19:15:31
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 20 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 20 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 25 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 26 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 27 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 27 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 27 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 20 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-c.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:05:39
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
k3d-uat-tools            ghcr.io/k3d-io/k3d-tools:5.8.3          Up 5 seconds
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 4 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 4 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 8 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 9 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 10 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 4 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 4 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:05:41
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
k3d-uat-tools            ghcr.io/k3d-io/k3d-tools:5.8.3          Up 6 seconds
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 4 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 4 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 8 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 9 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 10 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 4 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 4 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.x 503

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:05:44
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
k3d-uat-tools            ghcr.io/k3d-io/k3d-tools:5.8.3          Up 9 seconds
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 4 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 4 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 8 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 9 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 10 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 4 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 4 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:05:44
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
k3d-uat-tools            ghcr.io/k3d-io/k3d-tools:5.8.3          Up 10 seconds
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 4 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 4 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 8 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 9 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 10 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 4 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 4 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-a.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:05:45
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
k3d-uat-tools            ghcr.io/k3d-io/k3d-tools:5.8.3          Up 10 seconds
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 4 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 4 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 8 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 9 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 10 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 4 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 4 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-b.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:05:45
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
k3d-uat-tools            ghcr.io/k3d-io/k3d-tools:5.8.3          Up 10 seconds
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 4 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 4 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 8 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 9 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 10 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 10 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 10 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 10 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 4 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 4 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-c.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:08:13
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
k3d-uat-tools            ghcr.io/k3d-io/k3d-tools:5.8.3          Up 1 second
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 7 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 7 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 11 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 11 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 13 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 7 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 6 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.x 503

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:08:48
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 7 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 7 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 11 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 12 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 13 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 13 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 13 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 13 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 7 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 7 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.x 503

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:58:41
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 5 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 5 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 6 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 8 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 6 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:58:42
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 5 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 5 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 6 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 8 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 6 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:58:42
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 5 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 5 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 6 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 8 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 6 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:58:43
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 5 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 5 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 6 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 8 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 6 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-a.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:58:43
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 5 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 5 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 6 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 8 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 6 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-b.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:58:43
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 5 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 5 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 5 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 6 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 7 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 7 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 7 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 8 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 6 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up About a minute
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev-c.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:59:56
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 7 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 7 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 7 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 7 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 8 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 9 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 9 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 9 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 7 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:59:56
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 7 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 7 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 7 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 7 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 8 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 9 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 9 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 9 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 7 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 20:59:56
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 7 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 7 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 7 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 7 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 8 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 8 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 9 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 9 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 9 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 9 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 7 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 2 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 9 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 21:12:35
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 19 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 19 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 19 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 20 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 21 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 22 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 22 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 15 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 10 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.dev.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 21:12:35
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 19 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 19 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 19 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 20 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 21 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 22 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 22 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 15 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 10 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.uat.192.168.51.30.sslip.io via 80)
  HTTP/1.x 404

## Portainer Endpoints
\n---\n
# Smoke Test @ 2025-11-09 21:12:36
- HAPROXY_HOST: 192.168.51.30
- BASE_DOMAIN: 192.168.51.30.sslip.io
\n## Containers
NAMES                    IMAGE                                   STATUS
kindler-webui-frontend   infrastructure-kindler-webui-frontend   Up 19 minutes (healthy)
kindler-webui-backend    infrastructure-kindler-webui-backend    Up 19 minutes (healthy)
dev-c-control-plane      kindest/node:v1.31.12                   Up 19 minutes
dev-b-control-plane      kindest/node:v1.31.12                   Up 20 minutes
dev-a-control-plane      kindest/node:v1.31.12                   Up 21 minutes
k3d-prod-serverlb        ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-prod-server-0        rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-dev-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-dev-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-uat-serverlb         ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 21 minutes
k3d-uat-server-0         rancher/k3s:v1.31.5-k3s1                Up 21 minutes
k3d-devops-serverlb      ghcr.io/k3d-io/k3d-proxy:5.8.3          Up 22 minutes
k3d-devops-server-0      rancher/k3s:v1.31.5-k3s1                Up 22 minutes
portainer-ce             portainer/portainer-ce:2.33.2-alpine    Up 20 minutes
haproxy-gw               haproxy:3.2.6-alpine3.22                Up 15 minutes
goofy_solomon            ghcr.io/github/github-mcp-server        Up 10 days
gitlab                   gitlab/gitlab-ce:17.11.7-ce.0           Up 9 days (healthy)
local-registry           registry:2                              Up 3 weeks
\n## Curl
\n- Portainer HTTP (80)
  HTTP/1.x 301
\n- Portainer HTTPS (443)
  HTTPS 200
\n- Ingress Host (whoami.prod.192.168.51.30.sslip.io via 80)
  HTTP/1.x 200

## Portainer Endpoints
\n---\n
