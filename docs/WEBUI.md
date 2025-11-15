# Kindler Web GUI 使用指南

## 概述

Kindler Web GUI 是一个现代化的 Web 界面，用于管理 Kubernetes 集群（kind/k3d）。它提供了直观的图形界面来创建、删除、启动、停止集群，并实时监控操作进度。

## 功能特性

- ✅ **集群管理**: 创建、删除、启动、停止 kind/k3d 集群
- ✅ **实时进度**: WebSocket 实时推送任务进度和日志
- ✅ **并发操作**: 支持同时执行多个集群操作
- ✅ **自动注册**: 自动注册到 Portainer（Edge Agent）和 ArgoCD
- ✅ **路由配置**: 自动添加 HAProxy 路由规则
- ✅ **状态监控**: 实时显示集群节点状态和健康信息

## 架构

```
┌─────────────────────────────────────────────┐
│ HAProxy (haproxy-gw)                        │
│ - kindler.devops.192.168.51.30.sslip.io   │
└────────────┬────────────────────────────────┘
             │
             ├──> kindler-webui-frontend (Nginx)
             │    - Vue 3 + Naive UI
             │    - 代理 /api 和 /ws 到后端
             │
             └──> kindler-webui-backend (FastAPI)
                  - RESTful API
                  - WebSocket 实时推送
                  - 调用 Shell 脚本
                  - 访问 PostgreSQL
```

## 访问地址

- **Web GUI**: http://kindler.devops.192.168.51.30.sslip.io
- **API 文档**: http://kindler.devops.192.168.51.30.sslip.io/docs (Swagger UI)
- **健康检查**: http://kindler.devops.192.168.51.30.sslip.io/api/health

## 安装部署

### 1. 启动 Web GUI 服务

Web GUI 已集成到基础设施 Docker Compose 中：

```bash
cd compose/infrastructure
docker compose up -d kindler-webui-backend kindler-webui-frontend
```

或使用 bootstrap 脚本一键启动（包含所有基础服务）：

```bash
scripts/bootstrap.sh
```

### 2. 验证服务状态

```bash
# 检查容器状态
docker ps | grep kindler-webui

# 测试 API 健康检查
curl http://kindler.devops.192.168.51.30.sslip.io/api/health

# 测试前端访问
curl -I http://kindler.devops.192.168.51.30.sslip.io
```

### 3. 停止服务

```bash
docker compose -f compose/infrastructure/docker-compose.yml stop kindler-webui-backend kindler-webui-frontend
```

## 使用指南

### 创建集群

1. 访问 Web GUI 主页
2. 点击右上角"创建集群"按钮
3. 填写集群配置：
   - **集群名称**: 只能包含小写字母、数字和连字符（如 `dev`, `uat`, `prod-k3d`）
   - **Provider**: 选择 `kind` 或 `k3d`
   - **Node Port**: 默认 30080
   - **Port Forward Port**: 唯一端口，用于 kubectl port-forward
   - **HTTP Port**: HAProxy HTTP 映射端口
   - **HTTPS Port**: HAProxy HTTPS 映射端口
   - **集群子网**: 仅 k3d 需要，格式如 `10.101.0.0/16`
   - **注册选项**: 勾选是否注册到 Portainer、添加 HAProxy 路由、注册到 ArgoCD
4. 点击"创建"提交任务
5. 实时查看任务进度和日志
6. 创建完成后，集群自动出现在列表中

### 查看集群列表

主页自动显示所有集群，包括：
- 集群名称（点击可查看详情）
- Provider (kind/k3d)
- 运行状态（运行中、已停止、错误、未知）
- HTTP/HTTPS 端口
- 创建时间

### 查看集群详情

点击集群名称进入详情页，可以看到：
- 完整配置信息
- 节点状态（Ready/Total）
- Portainer 状态（online/offline）
- ArgoCD 状态（healthy/degraded）
- 快速链接（Whoami 应用、Portainer、ArgoCD）

### 启动/停止集群

在集群列表页面，每个集群有操作按钮：
- **启动**: 启动已停止的集群
- **停止**: 停止运行中的集群（保留配置和数据）
- **删除**: 永久删除集群（清理所有资源，不可恢复）

### 删除集群

1. 在集群列表找到要删除的集群
2. 点击"删除"按钮
3. 确认删除操作（⚠️ 此操作不可逆）
4. 实时查看删除进度
5. 删除完成后，集群从列表中移除

## API 文档

### RESTful API

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | /api/clusters | 列出所有集群 |
| POST | /api/clusters | 创建集群（返回 task_id） |
| GET | /api/clusters/{name} | 获取集群详情 |
| DELETE | /api/clusters/{name} | 删除集群（返回 task_id） |
| GET | /api/clusters/{name}/status | 获取集群运行状态 |
| POST | /api/clusters/{name}/start | 启动集群（返回 task_id） |
| POST | /api/clusters/{name}/stop | 停止集群（返回 task_id） |
| GET | /api/tasks/{task_id} | 查询任务状态 |
| GET | /api/health | 健康检查 |
| GET | /api/config | 获取系统配置 |

### WebSocket API

连接: `ws://kindler.devops.192.168.51.30.sslip.io/ws/tasks`

订阅任务更新：
```json
{
  "type": "subscribe",
  "task_id": "uuid-task-id"
}
```

接收任务更新：
```json
{
  "type": "task_update",
  "task": {
    "task_id": "uuid-task-id",
    "status": "running",
    "progress": 50,
    "message": "Creating cluster...",
    "logs": ["line1", "line2"]
  }
}
```

## 开发指南

### 本地开发

#### 后端开发

```bash
cd webui/backend

# 安装依赖
pip install -r requirements.txt

# 运行开发服务器
python -m app.main
# 或使用 uvicorn
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

#### 前端开发

```bash
cd webui/frontend

# 安装依赖
npm install

# 运行开发服务器
npm run dev
# 访问 http://localhost:3000
```

### 运行测试

#### API 单元测试

```bash
cd webui/tests
pip install -r requirements.txt
pytest api/ -v
```

#### E2E 测试

```bash
# 安装 Playwright 浏览器
playwright install chromium

# 运行基础 E2E 测试（需要服务运行）
pytest e2e/ -v -m "not slow"

# 运行完整 E2E 测试（会创建/删除真实集群）
E2E_FULL_TEST=1 pytest e2e/ -v
```

#### 一键运行所有测试

```bash
webui/tests/run_tests.sh all
```

### 构建 Docker 镜像

```bash
# 构建后端
docker build -t kindler-webui-backend:latest webui/backend/

# 构建前端
docker build -t kindler-webui-frontend:latest webui/frontend/
```

## 故障排查

### 1. 无法访问 Web GUI

```bash
# 检查容器状态
docker ps | grep kindler-webui

# 检查容器日志
docker logs kindler-webui-backend
docker logs kindler-webui-frontend

# 检查 HAProxy 配置
curl -I http://kindler.devops.192.168.51.30.sslip.io
```

### 2. API 请求失败

```bash
# 测试后端健康检查
docker exec kindler-webui-backend curl -f http://localhost:8000/api/health

# 检查后端日志
docker logs -f kindler-webui-backend
```

### 3. WebSocket 连接失败

```bash
# 检查 HAProxy 是否转发 WebSocket
docker logs haproxy-gw | grep ws

# 测试 WebSocket 端点
wscat -c ws://kindler.devops.192.168.51.30.sslip.io/ws/tasks
```

### 4. 集群创建失败

```bash
# 查看任务日志（在 Web GUI 中展开日志）
# 或直接查看脚本日志
tail -f logs/create_env_<cluster-name>.log

# 检查 devops 集群和 PostgreSQL
kubectl --context k3d-devops get pods -n paas
```

### 5. 数据库连接失败

```bash
# 检查 PostgreSQL Pod
kubectl --context k3d-devops get pods -n paas

# 测试数据库连接
kubectl --context k3d-devops exec -it postgresql-0 -n paas -- \
  psql -U kindler -d kindler -c "SELECT * FROM clusters;"
```

## 限制和注意事项

- **集群名称唯一性**: 同一集群名称不能重复创建
- **端口冲突**: HTTP/HTTPS/PF 端口必须唯一，避免冲突
- **并发限制**: 虽然支持并发，但建议同时运行的创建任务不超过 5 个
- **资源清理**: 删除集群会清理所有相关资源（K8s、Portainer、ArgoCD、Git、DB、HAProxy）
- **长时间操作**: 创建集群通常需要 2-3 分钟，删除需要 1-2 分钟
- **认证**: 当前版本无需认证，仅适用于内网环境

## 未来计划

- [ ] 用户认证和授权
- [ ] 集群配置更新（UPDATE 操作）
- [ ] 批量操作（批量创建/删除）
- [ ] 集群克隆功能
- [ ] 资源使用监控（CPU、内存、磁盘）
- [ ] 操作审计日志
- [ ] 邮件/Webhook 通知
- [ ] 多语言支持（英文）

## 历史案例与报告收缩说明

- 典型历史案例：
  - `docs/history/WEBUI_REAL_SCRIPTS_INTEGRATION_FINAL_REPORT.md`：WebUI 与脚本系统集成的最终总结。
  - `docs/history/WEB_UI_INTEGRATION_STATUS_FINAL.md`：WebUI 集成状态与问题的最终汇总。
- 其它 WebUI* 报告/总结类文档（例如 `WEBUI_FIX_REPORT.md`、`WEBUI_*_SUMMARY.md`、`WEBUI_*_REPORT.md` 等）已在 `shrink-file-inventory-tree` 变更中收敛到本规范、`docs/WEBUI_FIX_SUMMARY.md` 以及上述少量历史案例；如需完整过程可通过 Git 历史查看。

## 相关文档

- [项目 README](../README_CN.md)
- [API 接口文档](http://kindler.devops.192.168.51.30.sslip.io/docs)
- [测试文档](../tests/README.md)
- [开发者指南](../AGENTS.md)
