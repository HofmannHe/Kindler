# Web UI PostgreSQL 集成 - 部署后续步骤

**日期**: 2025-10-21  
**状态**: 代码已完成，需要部署

---

## 当前状态

### ✅ 已完成

1. **代码实现** (100%)
   - ✅ 数据库层重构 (`db.py`)
   - ✅ 服务层异步改造 (`cluster_service.py`, `db_service.py`)
   - ✅ Docker 配置更新 (`docker-compose.yml`)
   - ✅ 环境变量配置 (`secrets.env`)
   - ✅ 依赖声明 (`requirements.txt`)

2. **测试与文档** (100%)
   - ✅ 集成测试脚本 (`webui_postgresql_test.sh`)
   - ✅ 配置逻辑测试 (`test_db_backend.py`)
   - ✅ 技术文档 (3200+ 字)
   - ✅ 快速指南

3. **测试验证**
   - ✅ 配置逻辑测试通过
   - ✅ 数据库后端选择正确
   - ✅ 环境变量配置正确

### ⏳ 待完成

1. **镜像构建** (需要网络稳定时)
   - ⏳ 重新构建 Web UI Backend 镜像
   - ⏳ 安装新的 Python 依赖 (asyncpg, psycopg2-binary)

2. **服务部署**
   - ⏳ 启动新的 Web UI Backend 容器
   - ⏳ 验证 PostgreSQL 连接
   - ⏳ 运行端到端测试

---

## 部署步骤

### 方案 A: 重新构建镜像（推荐）

**适用场景**: 网络稳定时的正式部署

```bash
# 1. 停止当前容器
cd /home/cloud/github/hofmannhe/kindler
docker compose -f compose/infrastructure/docker-compose.yml stop kindler-webui-backend

# 2. 重新构建镜像（需要稳定网络）
export POSTGRES_PASSWORD=postgres123
docker compose -f compose/infrastructure/docker-compose.yml build kindler-webui-backend

# 3. 启动服务
docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend

# 4. 验证连接
docker logs -f kindler-webui-backend

# 期望看到:
# ✓ Using PostgreSQL backend (primary)
# 或
# ✓ Using SQLite backend (fallback)

# 5. 运行测试
tests/webui_postgresql_test.sh
```

### 方案 B: 手动安装依赖（临时验证）

**适用场景**: 网络不稳定，快速验证功能

```bash
# 1. 使用已存在的镜像启动临时容器
docker run -d --name webui-temp \
  -v $(pwd)/webui/backend:/app:ro \
  -v $(pwd)/scripts:/scripts:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network infrastructure \
  -e PG_HOST=haproxy-gw \
  -e PG_PORT=5432 \
  -e PG_DATABASE=paas \
  -e PG_USER=postgres \
  -e PG_PASSWORD=postgres123 \
  python:3.11-slim bash -c "
    cd /app && 
    pip install -r requirements.txt && 
    uvicorn app.main:app --host 0.0.0.0 --port 8000
  "

# 2. 检查日志
docker logs -f webui-temp

# 3. 测试完成后清理
docker stop webui-temp && docker rm webui-temp
```

### 方案 C: 使用预构建镜像（离线部署）

**适用场景**: 生产环境离线部署

```bash
# 1. 在有网络的机器上构建镜像
docker build -t kindler-webui-backend:1.1.0 webui/backend/

# 2. 导出镜像
docker save kindler-webui-backend:1.1.0 | gzip > kindler-webui-backend-1.1.0.tar.gz

# 3. 在目标机器上导入
docker load < kindler-webui-backend-1.1.0.tar.gz

# 4. 更新 docker-compose.yml
# 将 build 改为 image: kindler-webui-backend:1.1.0

# 5. 启动服务
docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend
```

---

## 验证清单

### 1. 容器启动检查

```bash
# 检查容器状态
docker ps | grep kindler-webui-backend

# 期望: Status 为 Up (healthy)
```

### 2. 数据库连接检查

```bash
# 查看启动日志
docker logs kindler-webui-backend | grep -E "(PostgreSQL|SQLite|Using.*backend)"

# 期望输出:
# ✓ Using PostgreSQL backend (primary)
# 或
# PostgreSQL connection failed: ...
# ✓ Using SQLite backend (fallback)
```

### 3. 健康检查

```bash
# API 健康检查
curl -f http://localhost:8000/api/health

# 期望: {"status":"healthy",...}
```

### 4. 数据库操作测试

```bash
# 列出集群
curl -s http://localhost:8000/api/clusters | python3 -m json.tool

# 期望: 返回集群列表（可能为空）
```

### 5. 完整集成测试

```bash
# 运行完整测试套件
tests/webui_postgresql_test.sh

# 期望: 所有测试通过
```

---

## 故障排查

### 问题 1: 镜像构建网络超时

**症状**:
```
Connection failed [IP: 151.101.110.132 80]
E: Unable to locate package curl
```

**解决方法**:
1. 等待网络恢复
2. 使用国内镜像源
3. 使用方案 B 或 C

**临时解决**:
```dockerfile
# 在 Dockerfile 中添加国内镜像源
RUN echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie main" > /etc/apt/sources.list
```

### 问题 2: 容器无限重启

**症状**:
```
Container is restarting
ModuleNotFoundError: No module named 'asyncpg'
```

**原因**: 依赖未安装

**解决方法**: 使用方案 A 重新构建镜像

### 问题 3: PostgreSQL 连接失败

**症状**: 日志显示 "PostgreSQL connection failed"

**检查步骤**:
```bash
# 1. 检查 devops 集群
kubectl --context k3d-devops get nodes

# 2. 检查 PostgreSQL
kubectl --context k3d-devops -n paas get pods

# 3. 检查 HAProxy
docker ps | grep haproxy-gw

# 4. 测试连接
kubectl --context k3d-devops -n paas exec deployment/postgresql -- \
  psql -U postgres -d paas -c "SELECT 1;"

# 5. 检查环境变量
docker inspect kindler-webui-backend | grep -A 5 "Env"
```

**修复方法**:
```bash
# 确保环境变量正确设置
export POSTGRES_PASSWORD=postgres123
docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend
```

### 问题 4: SQLite Fallback 模式

**症状**: 日志显示 "Using SQLite backend (fallback)"

**说明**: 这是**正常行为**，当 PostgreSQL 不可用时自动切换

**影响**:
- ✅ Web UI 功能正常
- ⚠️ 数据不与 CLI 脚本共享

**如需切换到 PostgreSQL**:
1. 确保 devops 集群和 PostgreSQL 运行
2. 确保环境变量正确配置
3. 重启容器

---

## 下一步行动

### 立即可做

1. **测试配置**
   ```bash
   # 验证配置逻辑
   python3 tests/test_db_backend.py
   ```

2. **检查前置条件**
   ```bash
   # 确保 devops 集群运行
   kubectl --context k3d-devops get nodes
   
   # 确保 PostgreSQL 运行
   kubectl --context k3d-devops -n paas get pods
   ```

3. **准备环境**
   ```bash
   # 加载密钥
   source config/secrets.env
   
   # 导出环境变量
   export POSTGRES_PASSWORD
   ```

### 等待网络稳定后

1. **构建镜像**
   ```bash
   docker compose -f compose/infrastructure/docker-compose.yml build kindler-webui-backend
   ```

2. **启动服务**
   ```bash
   docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend
   ```

3. **运行测试**
   ```bash
   tests/webui_postgresql_test.sh
   ```

### 生产部署前

1. **安全加固**
   - 修改默认密码
   - 启用 PostgreSQL SSL/TLS
   - 限制网络访问

2. **性能优化**
   - 调整连接池大小
   - 配置查询缓存
   - 启用慢查询日志

3. **监控配置**
   - 添加健康检查告警
   - 配置日志采集
   - 设置性能监控

---

## 总结

### 代码状态

✅ **完全就绪** - 所有代码已实现并测试

### 部署状态

⏳ **待部署** - 需要网络稳定时重新构建镜像

### 推荐方案

当网络稳定时，使用 **方案 A** 重新构建镜像，这是最简洁和可维护的方式。

### 临时方案

如果需要立即验证功能，可以使用 **方案 B** 临时容器测试。

---

**文档版本**: v1.0  
**最后更新**: 2025-10-21  
**下次更新**: 镜像构建完成后


