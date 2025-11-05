# WebUI 全局服务状态实现文档

## 概述

本文档记录了WebUI全局服务状态功能的实现，包括架构优化方案B的实施细节。

## 实施日期

2025-10-23

## 修改内容

### 1. 后端 API 修改

#### 新建文件: `webui/backend/app/api/services.py`

创建了全局服务状态API端点，支持查询Portainer、ArgoCD、HAProxy、Git服务的健康状态。

**功能**:
- HTTP健康检查（支持200/301/302状态码）
- 超时处理（5秒）
- SSL证书验证禁用（用于sslip.io）
- 返回结构化的服务状态信息

**端点**: `GET /api/services`

**响应格式**:
```json
{
  "portainer": {
    "name": "Portainer",
    "status": "healthy",
    "url": "http://portainer.devops.192.168.51.30.sslip.io",
    "message": "HTTP 301 Redirect"
  },
  "argocd": { ... },
  "haproxy": { ... },
  "git": { ... }
}
```

#### 修改文件: `webui/backend/app/main.py`

注册了services router:
```python
from .api import clusters, tasks, websocket, services
# ...
app.include_router(services.router)
```

### 2. 前端修改

#### 修改文件: `webui/frontend/src/api/client.js`

添加了servicesAPI:
```javascript
export const servicesAPI = {
  getGlobalStatus() {
    return apiClient.get('/services')
  }
}
```

#### 修改文件: `webui/frontend/src/views/ClusterList.vue`（首页）

**新增功能**:
1. 全局服务状态卡片
   - 显示Portainer、ArgoCD、HAProxy、Git的实时状态
   - 状态图标和颜色指示（healthy=绿色, degraded=黄色, offline=红色, unknown=灰色）
   - 快速访问链接（Portainer、ArgoCD）
   - 刷新按钮

2. 新增导入:
   ```javascript
   import { CheckmarkCircle, CloseCircle, AlertCircle, HelpCircle } from '@vicons/ionicons5'
   import { servicesAPI } from '../api/client'
   ```

3. 新增响应式数据:
   - `services`: 存储全局服务状态
   - `loadingServices`: 加载状态

4. 新增方法:
   - `loadServicesStatus()`: 加载全局服务状态
   - `getServiceIcon()`: 根据状态返回图标组件
   - `getServiceIconColor()`: 根据状态返回颜色

5. 生命周期:
   - 在`onMounted`中调用`loadServicesStatus()`

**UI布局**:
```
┌──────────────── 全局服务状态 ────────────────┐
│ [✓] Portainer: healthy  [✓] ArgoCD: healthy │
│ [✓] HAProxy: healthy    [✓] Git: healthy    │
│ [访问Portainer] [访问ArgoCD] [刷新状态]       │
└──────────────────────────────────────────────┘

┌──────────────── 集群列表 ────────────────────┐
│ ...                                           │
└──────────────────────────────────────────────┘
```

#### 修改文件: `webui/frontend/src/views/ClusterDetail.vue`（详情页）

**移除内容**:
- Portainer状态显示
- ArgoCD状态显示

**保留内容**:
- 节点状态
- 错误信息显示
- Whoami应用快速链接

**简化后的UI**:
```
┌──────────────── 集群信息 ────────────────────┐
│ 名称: dev                                     │
│ Provider: k3d                                 │
│ 状态: running                                 │
└──────────────────────────────────────────────┘

┌──────────────── 运行状态 ────────────────────┐
│ 节点状态: 2 / 2 Ready                         │
└──────────────────────────────────────────────┘

┌──────────────── 快速链接 ────────────────────┐
│ [访问Whoami应用] [Portainer] [ArgoCD]        │
└──────────────────────────────────────────────┘
```

## 部署说明

### 前提条件

- Docker镜像需要重新构建以包含最新代码
- 确保以下端口可用：
  - 后端: 8000（或8001如果8000被占用）
  - 前端: 3000

### 部署步骤

1. **重新构建WebUI镜像**:
   ```bash
   cd /home/cloud/github/hofmannhe/kindler
   docker compose -f webui/docker-compose.yml build
   ```

2. **启动服务**:
   ```bash
   docker compose -f webui/docker-compose.yml up -d
   ```

3. **验证部署**:
   ```bash
   # 测试后端API
   curl http://localhost:8000/api/services | jq '.'
   
   # 访问前端
   # 浏览器打开 http://localhost:3000
   ```

### 实际部署问题与解决方案（2025-10-23）

#### 问题1: Docker构建时清华源不可达

**现象**:
```
Err:1 http://mirrors.tuna.tsinghua.edu.cn/debian trixie InRelease
  Connection failed [IP: 101.6.15.130 80]
E: Unable to locate package curl
```

**原因**: 虽然主机能访问清华源，但Docker构建环境无法访问（可能是Docker网络配置或DNS问题）

**尝试的解决方案**:
1. ✗ 等待网络恢复 - 问题持续存在
2. ✗ 创建多镜像源Dockerfile - 构建阶段仍失败
3. ✓ **使用代码挂载方式** - 成功！

**最终方案**:
修改 `docker-compose.yml`，使用现有镜像 + 代码挂载：
```yaml
kindler-webui-backend:
  image: kindler-webui-backend:with-postgres
  volumes:
    - ./backend/app:/app/app:ro  # 挂载最新代码
```

#### 问题2: 前端构建失败 - 缺少依赖

**现象**:
```
Rollup failed to resolve import "@vicons/ionicons5" from "ClusterList.vue"
```

**原因**: 新增的图标库 `@vicons/ionicons5` 未在 `package.json` 中声明

**解决方案**: 
在 `webui/frontend/package.json` 添加依赖：
```json
"@vicons/ionicons5": "^0.12.0"
```

#### 问题3: 端口冲突

**现象**:
- 8000端口被HAProxy占用
- 3000端口被node进程占用

**解决方案**: 修改端口映射
```yaml
ports:
  - "8001:8000"  # 后端
  - "3001:80"    # 前端
```

### 最终部署命令

```bash
cd /home/cloud/github/hofmannhe/kindler
docker compose -f webui/docker-compose.yml up -d
```

**访问地址**:
- 前端: http://localhost:3001
- 后端: http://localhost:8001
- API:  http://localhost:8001/api/services

## 测试验证

### 后端API测试

```bash
# 测试全局服务状态端点
curl http://localhost:8000/api/services | jq '.'

# 预期响应：
# {
#   "portainer": { "status": "healthy", ... },
#   "argocd": { "status": "healthy", ... },
#   "haproxy": { "status": "healthy", ... },
#   "git": { "status": "healthy", ... }
# }
```

### 前端功能测试

1. **访问首页**:
   - 打开 http://localhost:3000
   - 验证全局服务状态卡片显示
   - 验证状态图标颜色正确
   - 点击"刷新状态"按钮测试

2. **访问集群详情页**:
   - 点击任一集群名称
   - 验证Portainer/ArgoCD状态已移除
   - 验证节点状态正常显示
   - 验证快速链接可用

## 架构优化效果

### Before（修改前）

**首页**:
- 仅显示集群列表
- 无全局服务状态可见性

**详情页**:
- 显示集群相关信息
- 显示Portainer/ArgoCD状态（与集群无关）

### After（修改后）

**首页**:
- ✅ 集群列表
- ✅ 全局服务状态卡片（Portainer、ArgoCD、HAProxy、Git）
- ✅ 快速访问链接
- ✅ 状态刷新功能

**详情页**:
- ✅ 集群相关信息
- ✅ 节点状态
- ✅ 快速链接（Whoami、Portainer、ArgoCD）
- ❌ 移除Portainer/ArgoCD状态（归属首页）

## 后续优化建议

1. **WebSocket实时更新**: 使用WebSocket推送服务状态变化，无需手动刷新
2. **历史记录**: 记录服务状态历史，支持趋势分析
3. **告警通知**: 服务状态异常时发送通知
4. **详细监控**: 添加响应时间、错误率等详细指标
5. **健康检查增强**: 支持自定义健康检查逻辑

## 相关文档

- [架构优化方案](./ARCHITECTURE_OPTIMIZATION_PROPOSAL.md)
- [WebUI PostgreSQL集成](./WEBUI_POSTGRESQL_INTEGRATION.md)
- [E2E测试报告](./E2E_TEST_VALIDATION_REPORT.md)

## 维护说明

- **API版本**: v0.1.0
- **前端框架**: Vue 3 + Naive UI
- **后端框架**: FastAPI
- **HTTP客户端**: httpx (异步)
- **图标库**: @vicons/ionicons5

## 问题排查

### API返回404

**原因**: 容器内代码未更新

**解决**: 重新构建镜像或使用docker cp复制新文件

### 服务状态显示unknown

**原因**: 
1. 网络连接问题
2. BASE_DOMAIN配置错误
3. 目标服务未启动

**解决**: 检查环境变量和服务状态

### 前端卡片不显示

**原因**: 
1. API请求失败
2. 前端代码未更新
3. 浏览器缓存

**解决**: 
```bash
# 清除浏览器缓存
# 或强制刷新 Ctrl+Shift+R
```

## 完成状态

- [x] 后端API实现
- [x] 前端client集成
- [x] 首页全局服务卡片
- [x] 详情页简化
- [ ] 部署验证（待网络恢复）
- [ ] E2E测试
- [ ] 用户验收

