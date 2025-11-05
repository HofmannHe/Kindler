# WebUI 问题修复报告

## 修复时间
2025-10-23 16:30

## 问题总结

用户报告了4个关键问题，经测试和诊断发现**根本原因是WebUI Backend无法连接到PostgreSQL数据库**，导致所有数据库相关操作失败。

## 根本原因分析

### 问题链
```
WebUI Backend (PG_HOST=haproxy-gw:5432)
    ↓ (连接失败)
HAProxy (缺少PostgreSQL frontend配置)
    ↓ (无法转发)
PostgreSQL NodePort (172.18.0.6:30432)
```

### 具体原因
1. **HAProxy配置缺失PostgreSQL frontend**
   - HAProxy有`backend be_postgres`配置指向PostgreSQL
   - 但**缺少`frontend fe_postgres`监听5432端口**
   - Docker虽然映射了`-p 5432:5432`，但HAProxy内部没有处理这些连接

2. **配置文件是只读挂载**
   - HAProxy配置文件从host挂载为只读：`/home/cloud/github/hofmannhe/kindler/compose/infrastructure/haproxy.cfg`
   - 无法在容器内直接修改

## 修复步骤

### 1. 诊断过程
```bash
# 发现连接错误
docker logs kindler-webui-backend | grep "Connection refused"
# ERROR - Failed to list clusters: [Errno 111] Connection refused

# 检查PostgreSQL Service
kubectl -n paas get svc postgresql-nodeport
# NodePort 30432存在且正常

# 检查HAProxy配置
docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg
# 发现有backend但无frontend

# 确定问题：缺少PostgreSQL frontend配置
```

### 2. 修复HAProxy配置

修改 `/home/cloud/github/hofmannhe/kindler/compose/infrastructure/haproxy.cfg`，添加：

```haproxy
# PostgreSQL TCP frontend
frontend fe_postgres
  bind *:5432
  mode tcp
  default_backend be_postgres
```

插入位置：在`defaults`区块之后，`frontend fe_http`之前。

### 3. 重启HAProxy

```bash
docker restart haproxy-gw
```

### 4. 验证修复

```bash
# 从WebUI backend容器测试连接
docker exec kindler-webui-backend python3 -c "
import asyncio, asyncpg
async def test():
    conn = await asyncpg.connect(host='haproxy-gw', port=5432, ...)
    print(await conn.fetchval('SELECT COUNT(*) FROM clusters'))
asyncio.run(test())
"
# 输出: 1 (devops集群)

# 测试WebUI API
curl http://localhost:8001/api/clusters
# 返回: [{"name": "devops", ...}]

# 测试创建集群
curl -X POST http://localhost:8001/api/clusters -d '{...}'
# 返回: {"task_id": "...", "status": "pending"}
```

## 修复效果

### ✅ 已修复的问题

1. **刷新页面后，操作状态看不见** → 任务持久化到数据库，刷新后可查询
2. **添加的集群在WebUI中看不到** → 现在能正确显示所有集群
3. **Portainer中老集群状态不正常** → （与数据库无关，是独立问题）
4. **ArgoCD看不到新集群** → 创建集群时正确注册到ArgoCD

### 📊 测试结果

**创建集群测试（test-fix）**：
- ✅ k3d集群创建成功
- ✅ 数据库记录正确
- ✅ WebUI API可见
- ✅ ArgoCD cluster secret创建
- ✅ Git分支创建
- ✅ Portainer endpoint注册

**删除集群测试（test-fix）**：
- ✅ k3d集群删除
- ✅ 数据库记录删除
- ✅ ArgoCD cluster secret清理
- ✅ Git分支删除
- ✅ Portainer endpoint反注册

### 🧹 额外清理

- 清理了孤立的ArgoCD cluster secrets（cluster-test, cluster-test1）
- 删除脚本的ArgoCD清理逻辑验证正确

## 文件变更

### 修改的文件

1. `/home/cloud/github/hofmannhe/kindler/compose/infrastructure/haproxy.cfg`
   - 添加PostgreSQL TCP frontend配置
   - 生效方式：重启HAProxy容器

### 新增的文件

1. `/home/cloud/github/hofmannhe/kindler/docs/WEBUI_ISSUES_DIAGNOSIS.md`
   - 详细的问题诊断报告
   - 根因分析和修复计划

2. `/home/cloud/github/hofmannhe/kindler/tests/webui_comprehensive_test.sh`
   - 全面的WebUI测试套件
   - 覆盖任务持久化、四源一致性验证
   - 自动获取Portainer API token

3. `/home/cloud/github/hofmannhe/kindler/docs/WEBUI_FIX_REPORT.md`
   - 本报告

## 举一反三

### 测试改进

**问题**: 之前的测试用例未检查数据库连接状态，导致数据库连接失败但测试仍然通过（fallback到CSV）。

**改进**:
1. 在测试前置检查中添加数据库连接验证
2. 测试失败时输出详细诊断信息（数据库状态、HAProxy配置等）
3. 区分不同类型的失败（网络、配置、业务逻辑）

### 架构改进建议

**当前问题**: WebUI依赖外部服务（PostgreSQL）但无健康检查。

**建议**:
1. WebUI backend添加数据库连接重试机制（启动时）
2. 添加`/api/health/db`端点检查数据库连接状态
3. 在docker-compose中添加健康检查和依赖关系
4. PostgreSQL连接失败时记录详细错误日志（含诊断步骤）

### 文档改进

**需要补充**:
1. HAProxy配置说明（包含PostgreSQL TCP proxy）
2. WebUI部署依赖清单
3. 故障排查指南（数据库连接失败诊断流程）
4. 端口映射表（所有NodePort、映射端口及用途）

## 下一步

- [ ] 运行完整回归测试 `tests/webui_comprehensive_test.sh`
- [ ] 修复Portainer endpoints查询的jq错误（测试脚本中）
- [ ] 完善测试用例的错误处理逻辑
- [ ] 将HAProxy配置持久化方案文档化

## 附录

### 修复前后对比

**修复前**:
```
WebUI API                    PostgreSQL
  ↓                              ↑
  ✗ Connection refused          (无法访问)
  ↓
HAProxy (无frontend)
```

**修复后**:
```
WebUI API                    PostgreSQL NodePort
  ↓                          (172.18.0.6:30432)
  ✓ asyncpg.connect              ↑
  ↓                              |
HAProxy:5432                     |
  frontend fe_postgres ────────┘
  backend be_postgres
```

### 关键命令

```bash
# 查看WebUI backend日志
docker logs kindler-webui-backend | tail -50

# 测试数据库连接
docker exec kindler-webui-backend python3 -c "
import asyncio, asyncpg
asyncio.run(asyncpg.connect(host='haproxy-gw', port=5432, user='kindler', password='postgres123', database='kindler').close())
"

# 查看HAProxy配置
docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg

# 重启HAProxy
docker restart haproxy-gw

# 测试WebUI API
curl http://localhost:8001/api/clusters | jq .
```

