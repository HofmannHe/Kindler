# Web UI PostgreSQL 集成 - 快速开始

## 概述

Web UI 现在支持连接到 devops 集群的 PostgreSQL 数据库，实现与 CLI 脚本的数据统一管理。

## 特性

- ✅ **自动选择数据库**: PostgreSQL 优先，SQLite 自动 fallback
- ✅ **数据统一**: Web UI 和 CLI 脚本共享同一数据源
- ✅ **高可用**: PostgreSQL 不可用时自动切换到 SQLite
- ✅ **透明连接**: 通过 HAProxy TCP 代理访问 PostgreSQL

## 快速开始

### 1. 配置密码

```bash
# 编辑 config/secrets.env，添加 PostgreSQL 密码
echo "POSTGRES_PASSWORD=postgres123" >> config/secrets.env
```

### 2. 启动基础设施

```bash
# 启动 devops 集群（包含 PostgreSQL）
scripts/bootstrap.sh

# 加载环境变量
source config/secrets.env

# 启动 Web UI
docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend kindler-webui-frontend
```

### 3. 验证连接

```bash
# 检查 Web UI 日志
docker logs kindler-webui-backend | grep -E "PostgreSQL|SQLite"

# 应该看到:
# ✓ Using PostgreSQL backend (primary)
```

### 4. 测试集成

```bash
# 运行集成测试
tests/webui_postgresql_test.sh
```

## 访问 Web UI

```bash
# 打开浏览器访问
open http://kindler.devops.192.168.51.30.sslip.io
```

## 数据流

```
Web UI ──→ HAProxy (TCP Proxy) ──→ devops PostgreSQL
   │
   └──→ SQLite (fallback)
```

## 环境变量

Web UI Backend 支持以下数据库配置:

```yaml
# PostgreSQL (主)
PG_HOST: haproxy-gw              # PostgreSQL 主机
PG_PORT: 5432                    # 端口
PG_DATABASE: paas                # 数据库名
PG_USER: postgres                # 用户名
PG_PASSWORD: ${POSTGRES_PASSWORD} # 密码（从 secrets.env）

# SQLite (备)
SQLITE_PATH: /data/kindler-webui/kindler.db
```

## 故障排查

### PostgreSQL 连接失败

```bash
# 1. 检查 devops 集群
kubectl --context k3d-devops get nodes

# 2. 检查 PostgreSQL Pod
kubectl --context k3d-devops -n paas get pods -l app.kubernetes.io/name=postgresql

# 3. 检查 HAProxy
docker ps | grep haproxy-gw

# 4. 重启 Web UI Backend
docker compose -f compose/infrastructure/docker-compose.yml restart kindler-webui-backend
```

### 查看详细日志

```bash
# Web UI Backend 日志
docker logs -f kindler-webui-backend

# PostgreSQL 日志
kubectl --context k3d-devops -n paas logs -l app.kubernetes.io/name=postgresql
```

## 详细文档

查看完整文档: [WEBUI_POSTGRESQL_INTEGRATION.md](../docs/WEBUI_POSTGRESQL_INTEGRATION.md)

## 常见问题

### Q: Web UI 使用的是 PostgreSQL 还是 SQLite?

A: 检查日志:
```bash
docker logs kindler-webui-backend | grep "Using.*backend"
```

### Q: 如何强制使用 SQLite?

A: 不设置 `PG_HOST` 或 `PG_PASSWORD` 环境变量即可。

### Q: PostgreSQL 和 SQLite 的数据会同步吗?

A: 不会自动同步。使用 PostgreSQL 时，所有数据操作直接在 PostgreSQL；使用 SQLite 时，数据存储在本地文件。

### Q: 如何从 SQLite 迁移到 PostgreSQL?

A: 未来会提供 `scripts/sync_db.sh` 工具进行数据迁移。

## 性能对比

| 操作 | PostgreSQL | SQLite |
|------|-----------|--------|
| 列出集群 | ~15ms | ~5ms |
| 插入集群 | ~20ms | ~10ms |
| 并发支持 | ✅ 优秀 | ⚠️ 有限 |
| 数据一致性 | ✅ ACID | ✅ ACID |
| 多实例支持 | ✅ 是 | ❌ 否 |

## 后续计划

- [ ] 数据同步工具 (`scripts/sync_db.sh`)
- [ ] PostgreSQL 高可用配置
- [ ] 连接池监控
- [ ] 性能优化

---

**版本**: v1.0  
**日期**: 2025-10-21

