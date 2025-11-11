# 集群配置管理架构方案

> **文档版本**: v2.0  
> **更新时间**: 2025-10-19  
> **状态**: 已实施

---

## 方案概述

Kindler 项目的业务集群配置管理采用 **PostgreSQL + Git 分支自动管理** 的架构，PostgreSQL 作为唯一真实数据源（Single Source of Truth），Git 分支由脚本自动管理，CSV 文件作为过渡期的 fallback 机制。

### 核心原则

1. **单一数据源**: PostgreSQL 是业务集群配置的唯一真实来源
2. **衍生数据**: Git 分支和 CSV 文件都是从 DB 衍生的数据
3. **脚本管理**: 禁止手动创建/删除 Git 分支，必须通过脚本操作
4. **可诊断性**: 提供完整的检查和修复工具链
5. **低频操作**: 针对环境创建/删除这类低频操作设计，允许手动介入

---

## 架构组件

### 1. PostgreSQL 数据库

**位置**: devops 集群 `paas` namespace  
**表结构**: `clusters`

```sql
CREATE TABLE clusters (
    name VARCHAR(63) PRIMARY KEY,
    provider VARCHAR(10) NOT NULL CHECK (provider IN ('k3d', 'kind')),
    subnet CIDR,
    node_port INTEGER NOT NULL,
    pf_port INTEGER NOT NULL,
    http_port INTEGER NOT NULL,
    https_port INTEGER NOT NULL,
    created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

**作用**:
- 存储所有业务集群的元数据
- 支持并发访问和事务一致性
- 提供 CRUD 操作接口 (`scripts/lib_db.sh`)

### 2. Git 分支（衍生数据）

**仓库**: 外部 Git 服务 (config/git.env 配置)  
**分支命名**: 集群名 = 分支名 (如 dev, uat, prod, dev-k3d)

**作用**:
- 存储每个业务集群的 whoami 应用 manifests
- 作为 ArgoCD ApplicationSet 的数据源
- 实现 GitOps 工作流

**保留分支**:
- `main` / `master`: 项目主分支
- `develop`: 开发分支
- `release`: 发布分支
- `devops`: PaaS 服务 manifests（PostgreSQL, pgAdmin 等）

**业务分支**: 每个业务集群一个同名分支

### 3. environments.csv（过渡 Fallback）

**位置**: `config/environments.csv`

**作用**:
- 仅在 PostgreSQL 不可用时使用
- 未来版本将完全移除
- 不得手动编辑（由脚本自动生成）

---

## 操作流程

### 创建集群

```bash
scripts/create_env.sh -n dev -p k3d
```

**执行步骤**:
1. 检查 DB 中是否已存在
2. **插入 DB 记录** (关键步骤)
3. 创建 Git 分支（含 whoami manifests）
4. 创建 K8s 集群
5. 注册到 Portainer (Edge Agent)
6. 注册到 ArgoCD
7. 添加 HAProxy 路由

**错误处理**:
- Git 操作失败 → 显示错误，提示检查 Git 服务和凭证
- DB 操作失败 → 显示 SQL 错误，提示检查 devops 集群
- 部分失败 → 记录中间状态，提供恢复命令

### 删除集群

```bash
scripts/delete_env.sh -n dev
```

**执行步骤**:
1. 删除 K8s 集群
2. 反注册 Portainer/ArgoCD
3. 删除 HAProxy 路由
4. **删除 Git 分支**
5. **删除 DB 记录** (关键步骤)

**错误处理**:
- Git 操作失败 → 记录警告，不阻断删除流程
- 提供手动清理命令

### 一致性检查

```bash
scripts/check_consistency.sh
```

**检查内容**:
- DB 记录数量 vs Git 分支数量 vs K8s 集群数量
- 集群名称是否完全匹配
- 是否存在孤立资源

**输出示例**:
```
✓ DB: 6 clusters
✓ Git: 6 branches
✓ K8s: 6 clusters running
✗ Inconsistency found:
  - Cluster 'test' in DB but Git branch missing
  Suggested fix: tools/git/sync_git_from_db.sh
```

### 同步修复

```bash
tools/git/sync_git_from_db.sh
```

**作用**: 根据 DB 记录重建所有 Git 分支

**使用场景**:
- Git 操作失败后修复
- 手动删除了分支需要恢复
- 批量清理临时分支后重建

---

## 优势分析

### 1. 单一数据源

**优势**:
- 避免 DB、Git、CSV 三者不一致
- 简化数据流向：DB → (派生) → Git + CSV
- 明确的数据权威性

**数据流**:
```
PostgreSQL (Source of Truth)
    ↓
    ├─→ Git 分支 (ArgoCD 读取)
    └─→ CSV 文件 (Fallback, 未来移除)
```

### 2. 并发安全

**优势**:
- PostgreSQL 事务机制保证并发创建集群的一致性
- 多用户/多进程可安全并行操作
- 避免 CSV 文件的并发写入冲突

**场景**: 团队成员可同时创建不同环境，无需担心配置冲突

### 3. GitOps 兼容

**优势**:
- 保留完整的 ArgoCD + Git 工作流
- 应用 manifests 版本化、可审计
- 支持回滚和变更追踪

**实现**: ApplicationSet 从 Git 分支读取 manifests，ArgoCD 自动同步

### 4. 过渡平滑

**优势**:
- CSV fallback 确保向后兼容
- 数据库不可用时系统仍可运行（降级模式）
- 渐进式迁移，无需一次性切换

### 5. 可诊断性强

**优势**:
- 提供完整的诊断工具链
- 清晰的错误提示和修复建议
- 支持一致性检查和自动修复

**工具**:
- `check_consistency.sh`: 一致性检查
- `sync_git_from_db.sh`: 同步修复
- `tools/maintenance/cleanup_orphaned_branches.sh`: 清理孤立分支
- `tools/maintenance/cleanup_orphaned_clusters.sh`: 清理孤立集群

---

## 挑战与缓解

### 挑战 1: DB-Git 双写一致性

**问题**: 
- DB 插入成功但 Git 分支创建失败
- Git 推送成功但 DB 已回滚
- 如何保证两者始终一致？

**缓解措施**:
1. **操作顺序**: DB 先写（易回滚）→ Git 后写（失败不影响 DB）
2. **幂等操作**: Git 分支创建支持重复执行
3. **一致性检查**: 定期运行 `check_consistency.sh`
4. **同步修复**: 提供 `sync_git_from_db.sh` 快速修复
5. **用户介入**: 低频操作允许手动修复，脚本提供清晰指引

**实践**:
- Git 操作失败时，显示详细错误和恢复命令
- 不强制要求 100% 自动化，用户可手动调用修复脚本

### 挑战 2: 外部 Git 依赖

**问题**:
- 外部 Git 服务可能不可用（已遇到 503 错误）
- 网络故障、权限问题、仓库满等

**缓解措施**:
1. **详细错误提示**: 显示 Git 错误，指导用户排查
2. **非阻断删除**: 删除集群时 Git 操作失败不阻断流程
3. **CSV Fallback**: 数据库不可用时自动使用 CSV
4. **未来演进**: 可部署内置 Gitea 消除外部依赖

**实践**:
- 创建集群时 Git 失败 → 停止创建，提示修复
- 删除集群时 Git 失败 → 记录警告，继续删除，提供手动清理命令

### 挑战 3: 操作复杂度

**问题**:
- 用户需要理解 DB、Git、K8s 三者关系
- 错误排查需要多个工具

**缓解措施**:
1. **脚本自动化**: 所有操作通过单一命令完成
2. **清晰输出**: 每个步骤显示进度和状态
3. **诊断工具**: 提供专门的检查和修复脚本
4. **文档完善**: 详细的操作指南和故障排除

**实践**:
- 用户只需执行 `create_env.sh` 或 `delete_env.sh`
- 出错时脚本提供清晰的下一步操作建议
- 文档中包含常见问题和解决方案

---

## 适用场景

### ✅ 适合的场景

1. **开发/测试环境** (当前)
   - 集群创建/删除频率低（< 10次/天）
   - 允许短暂的不一致状态
   - 可接受手动介入修复

2. **小团队** (≤10人)
   - 并发创建集群需求不高
   - 团队成员可协调操作
   - 简单的权限管理

3. **轻量级部署**
   - 不需要额外的 Git 服务
   - 可复用现有外部 Git
   - 最小化基础设施

### ⚠️ 需要增强的场景

1. **生产环境**
   - 建议部署内置 Gitea
   - 增强错误处理和回滚机制
   - 添加审计日志

2. **大团队** (>10人)
   - 考虑引入锁机制
   - 增强并发控制
   - 完善权限管理

3. **高频操作**
   - 优化 Git 操作性能
   - 考虑批量操作接口
   - 添加操作队列

---

## 未来演进

### 短期（1-3个月）

1. **完善测试覆盖**
   - 增加一致性测试用例
   - 模拟 Git 失败场景
   - 验证修复工具有效性

2. **性能优化**
   - Git 操作并行化
   - 批量同步接口
   - 缓存机制

3. **用户体验**
   - 改进错误提示
   - 增加操作确认
   - 提供回滚命令

### 中期（3-6个月）

1. **内置 Git 服务**
   - 在 devops 集群部署 Gitea
   - 通过 API 管理分支（更可靠）
   - 消除外部 Git 依赖

2. **配置版本化**
   - 集群配置变更历史
   - 支持回滚到历史版本
   - 配置 diff 和审计

3. **Web UI**
   - 集群管理界面
   - 可视化一致性检查
   - 操作日志查询

### 长期（6-12个月）

1. **去分支化**
   - 单一 manifests 源
   - ApplicationSet 从 DB 读取配置
   - Git 仅作为 manifests 存储

2. **多集群管理**
   - 支持跨 DC/Region
   - 集群分组和标签
   - 批量操作

3. **自动化修复**
   - 监控一致性状态
   - 自动触发修复流程
   - 告警和通知

---

## 总体评价

### 评分（5分制）

- **可靠性**: ⭐⭐⭐⭐ (4/5)
  - 提供完整的一致性保证机制
  - 需依赖外部 Git 服务

- **易用性**: ⭐⭐⭐⭐⭐ (5/5)
  - 单一命令完成所有操作
  - 清晰的错误提示和修复建议

- **可维护性**: ⭐⭐⭐⭐ (4/5)
  - 提供完整的诊断工具链
  - 需要理解 DB-Git-K8s 三者关系

- **扩展性**: ⭐⭐⭐ (3/5)
  - 适合小规模部署
  - 需要增强以支持生产环境

- **性能**: ⭐⭐⭐⭐ (4/5)
  - 适合低频操作
  - Git 操作可能成为瓶颈

**总体**: ⭐⭐⭐⭐ (4/5)

### 结论

该方案是从 CSV 静态配置向数据库动态管理的**自然演进**，在简单性和可靠性之间取得了良好的平衡。对于开发/测试环境和小团队来说，是一个**合理且可行**的解决方案。

关键是要**实现好错误处理和一致性保证机制**，并提供**充分的诊断和修复工具**。随着项目发展，可以逐步演进到内置 Git 服务或完全去分支化的方案。

---

## 参考资料

- [集群配置管理规范](../AGENTS.md#集群配置管理)
- [诊断与维护工具](../AGENTS.md#诊断与维护工具)
- [回归测试标准](../AGENTS.md#回归测试标准)
- [E2E 服务测试报告](E2E_TEST_VALIDATION_REPORT.md)
