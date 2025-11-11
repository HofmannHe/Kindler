# 数据存储架构对比分析

## 当前问题

### 数据源过多（三个）
1. **PostgreSQL**（devops 集群 paas namespace）
2. **CSV 文件**（config/environments.csv）
3. **SQLite**（Web UI backend）

### 一致性问题
- 数据同步复杂（三向同步）
- 容易出现不一致
- 维护成本高

---

## 方案对比

### 方案 A：CSV 作为唯一真实来源（当前设计）

#### 优点
- ✅ **简单直观**：人类可读，易于手工编辑
- ✅ **版本控制友好**：Git 可以跟踪变更
- ✅ **无依赖**：不需要数据库服务
- ✅ **备份简单**：就是一个文本文件
- ✅ **配置即代码**：符合 IaC 理念

#### 缺点
- ❌ **并发写入不安全**：多个进程同时写会冲突
- ❌ **查询能力弱**：没有索引、JOIN、聚合
- ❌ **事务支持弱**：无 ACID 保证
- ❌ **数据验证弱**：依赖应用层验证
- ❌ **扩展性差**：列数固定，增加字段需要迁移

#### 适用场景
- 配置项少于 100 条
- 读多写少
- 单进程或串行写入
- 不需要复杂查询

---

### 方案 B：SQLite 作为唯一真实来源（推荐）

#### 优点
- ✅ **ACID 事务**：保证数据一致性
- ✅ **并发安全**：支持多读单写
- ✅ **查询能力强**：完整 SQL 支持
- ✅ **数据验证**：CHECK 约束、外键
- ✅ **无需服务**：嵌入式数据库
- ✅ **备份简单**：单文件备份
- ✅ **扩展性好**：ALTER TABLE 轻松增加字段
- ✅ **成熟稳定**：广泛使用，久经考验

#### 缺点
- ❌ **不能直接编辑**：需要工具或脚本
- ❌ **Git diff 不友好**：二进制文件
- ❌ **多进程写入限制**：虽然支持但性能一般

#### 适用场景
- 需要事务保证
- 多进程读写
- 需要复杂查询
- 数据结构可能变化

---

### 方案 C：PostgreSQL 作为唯一真实来源（过度设计）

#### 优点
- ✅ **企业级特性**：完整的关系数据库
- ✅ **高并发**：支持大量并发连接
- ✅ **扩展性**：可以添加更多表、视图、函数

#### 缺点
- ❌ **过度复杂**：需要运行服务、管理连接
- ❌ **依赖 K8s**：必须先有 devops 集群
- ❌ **访问复杂**：需要 kubectl exec 或网络暴露
- ❌ **资源占用**：内存和 CPU 开销
- ❌ **备份复杂**：需要 pg_dump 等工具

#### 适用场景
- 大规模生产环境（数千台服务器）
- 需要多表关联
- 需要复杂查询和事务
- 已有 PostgreSQL 基础设施

---

## 推荐架构：SQLite + CSV 导出

### 核心设计

```
┌─────────────────────────────────────────────┐
│           SQLite (唯一真实来源)              │
│         /data/kindler.db                    │
│                                             │
│  - clusters 表（主数据）                     │
│  - operations 表（操作日志）                 │
│  - ACID 事务保证                            │
└─────────────────────────────────────────────┘
           │
           ├─ 读取 ───> CLI 脚本 (create_env.sh, delete_env.sh)
           ├─ 读取 ───> Web UI Backend
           └─ 导出 ───> environments.csv (只读，用于版本控制和审计)
```

### 数据流

1. **写入路径**（唯一）：
   ```
   create_env.sh → SQLite.insert()
   delete_env.sh → SQLite.delete()
   Web UI → SQLite.insert()/delete()
   ```

2. **读取路径**：
   ```
   所有脚本 → SQLite.query()
   Web UI → SQLite.query()
   ```

3. **导出路径**（定期）：
   ```
   SQLite → 导出脚本 → environments.csv
   CSV → Git commit → 版本历史
   ```

### 实现要点

#### 1. 统一 SQLite 访问层
```bash
# scripts/lib_sqlite.sh
DB_PATH="${DB_PATH:-/data/kindler.db}"

sqlite_exec() {
  sqlite3 "$DB_PATH" "$@"
}

sqlite_insert_cluster() {
  local name=$1 provider=$2 subnet=$3 node_port=$4 pf_port=$5 http_port=$6 https_port=$7
  sqlite_exec "INSERT INTO clusters (name, provider, subnet, node_port, pf_port, http_port, https_port) 
               VALUES ('$name', '$provider', '$subnet', $node_port, $pf_port, $http_port, $https_port);"
}

sqlite_query_cluster() {
  local name=$1
  sqlite_exec "SELECT * FROM clusters WHERE name='$name';"
}
```

#### 2. CSV 作为只读导出
```bash
# scripts/export_csv.sh
#!/usr/bin/env bash
# 从 SQLite 导出到 CSV（只读，用于版本控制）

DB_PATH="${DB_PATH:-/data/kindler.db}"
CSV_PATH="${CSV_PATH:-config/environments.csv}"

echo "# Exported from SQLite at $(date)" > "$CSV_PATH"
sqlite3 -header -csv "$DB_PATH" "SELECT * FROM clusters;" >> "$CSV_PATH"

git add "$CSV_PATH"
git commit -m "chore: export cluster config from SQLite"
```

#### 3. 移除 PostgreSQL 依赖
- 保留 PostgreSQL 服务（用于其他 PaaS 需求）
- 移除 clusters 表
- 所有集群配置操作直接访问 SQLite

---

## 迁移方案

### Phase 1: 建立 SQLite 优先（当前阶段）
- ✅ Web UI 已使用 SQLite
- ⏳ CLI 脚本还在用 CSV + PostgreSQL

### Phase 2: CLI 脚本迁移到 SQLite（建议）
1. 创建 `scripts/lib_sqlite.sh` 统一访问层
2. 修改 `create_env.sh` 使用 SQLite
3. 修改 `delete_env.sh` 使用 SQLite
4. 修改 `cluster.sh list` 使用 SQLite（或通过 SQLite 提供数据）

### Phase 3: CSV 降级为只读导出
1. 创建 `scripts/export_csv.sh`
2. 在 `create_env.sh` / `delete_env.sh` 完成后自动导出
3. CSV 仅用于版本控制和审计

### Phase 4: 移除 PostgreSQL clusters 表
1. 删除数据库初始化脚本中的 clusters 表
2. PostgreSQL 仅用于其他 PaaS 服务（如应用数据）
3. 简化架构

---

## 对比总结

| 维度 | CSV | SQLite | PostgreSQL |
|-----|-----|--------|-----------|
| **简单性** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ |
| **可靠性** | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **并发性** | ⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **查询能力** | ⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **易于编辑** | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐ |
| **版本控制** | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐ |
| **资源消耗** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| **扩展性** | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **适合规模** | <100 条 | <100万条 | 无限制 |

---

## 最终推荐

### 当前项目（Kindler）

**推荐方案**：**SQLite 作为主存储 + CSV 只读导出**

**理由**：
1. ✅ 集群数量有限（通常 <50 个）
2. ✅ 需要事务保证（创建/删除操作）
3. ✅ Web UI 和 CLI 脚本共享数据
4. ✅ 无需额外服务（嵌入式）
5. ✅ CSV 导出满足版本控制需求
6. ✅ 简化架构（移除 PostgreSQL 依赖）

**PostgreSQL 保留用途**：
- 其他 PaaS 服务数据（非集群配置）
- 应用业务数据存储
- 多租户隔离场景

---

## 行动建议

### 立即行动（优先级 P0）
1. ✅ 修复 Web UI Demo 模式问题（已完成）
2. ✅ 修复 WebSocket 序列化问题（已完成）
3. ⏳ 创建 `scripts/lib_sqlite.sh` 统一访问层

### 短期行动（优先级 P1）
4. ⏳ 修改 CLI 脚本使用 SQLite（create_env.sh, delete_env.sh）
5. ⏳ 创建 `scripts/export_csv.sh` 导出脚本
6. ⏳ 更新文档说明新架构

### 中期行动（优先级 P2）
7. ⏳ 移除 PostgreSQL clusters 表
8. ⏳ 简化 bootstrap.sh 脚本
9. ⏳ 添加 SQLite 数据迁移工具

---

**文档版本**: v1.0  
**生成时间**: 2025-10-21  
**作者**: AI Assistant
