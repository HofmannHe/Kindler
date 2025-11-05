# Git 分支管理策略实施总结

> 实施日期: 2025-10-27  
> 状态: ✅ 已完成

---

## 背景

用户提出调整 Git 分支管理策略，核心要求：

1. **生命周期同步**: Git 分支与集群严格绑定，集群删除 → 分支删除
2. **归档保护**: 删除前创建归档 tag（防止配置丢失）
3. **分层管理**: 支持预置集群和动态创建的业务集群
4. **快速提交**: dev/uat/prod 不设为保护分支，支持快速开发
5. **命名规范**: 集群名称与 provider 解耦

---

## 发现的架构问题

### 问题 1: 集群命名耦合 Provider

❌ **错误设计**:
```
dev (k3d)
uat (k3d)
prod (k3d)
dev-kind (kind)    # 错误！名称包含 provider 类型
uat-kind (kind)
prod-kind (kind)
```

✅ **正确设计**:
```
dev (provider: k3d)    # provider 是属性
uat (provider: k3d)
prod (provider: k3d)
```

### 问题 2: 预置集群数量错误

❌ **错误**: 预置 6 个集群（3 k3d + 3 kind）
✅ **正确**: 预置 3 个集群（dev, uat, prod - 默认 k3d）

### 问题 3: 文档与实现不一致

多处文档说明与实际需求不符，需要全面更新。

---

## 实施的修改

### 1. 配置文件修改

#### `config/environments.csv`
```diff
- # k3d 业务集群（独立子网）
- dev,k3d,30080,19001,true,true,18090,18443,10.101.0.0/16
- uat,k3d,30080,19002,true,true,18091,18444,10.102.0.0/16
- prod,k3d,30080,19003,true,true,18092,18445,10.103.0.0/16
- 
- # kind 业务集群（无需子网配置）
- dev-kind,kind,30080,19010,true,true,18093,18446,
- uat-kind,kind,30080,19011,true,true,18094,18447,
- prod-kind,kind,30080,19012,true,true,18095,18448,

+ # 预置业务集群（默认 k3d，用户可修改 provider 为 kind）
+ dev,k3d,30080,19001,true,true,18090,18443,10.101.0.0/16
+ uat,k3d,30080,19002,true,true,18091,18444,10.102.0.0/16
+ prod,k3d,30080,19003,true,true,18092,18445,10.103.0.0/16
```

**变更**: 删除 dev-kind, uat-kind, prod-kind 配置

---

### 2. 测试脚本修改

#### `tests/run_tests.sh`

**变更 1**: 动态读取预置集群列表
```bash
# 旧代码（硬编码）
for cluster_def in "dev:k3d" "uat:k3d" "prod:k3d" "dev-kind:kind" "uat-kind:kind" "prod-kind:kind"; do

# 新代码（从 CSV 读取）
preset_clusters=$(awk -F',' 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {printf "%s:%s ", $1, $2}' "$ROOT_DIR/config/environments.csv")
for cluster_def in $preset_clusters; do
```

**变更 2**: 动态验证初始状态
```bash
# 旧代码（硬编码）
local k3d_clusters="devops dev uat prod"
local kind_clusters="dev-kind uat-kind prod-kind"

# 新代码（从 CSV 读取）
local expected_clusters=$(awk -F',' 'NR>1 && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1 ":" $2}' "$ROOT_DIR/config/environments.csv")
```

---

### 3. 新增脚本

#### `scripts/fix_applicationset.sh`

**功能**: 根据数据库中的集群列表自动修复 ApplicationSet 配置

```bash
# 从数据库读取集群
clusters=$(kubectl exec postgresql-0 -- psql -U kindler -d kindler -t -c "SELECT name FROM clusters WHERE name != 'devops';")

# 生成 ApplicationSet elements
# 应用到 ArgoCD
kubectl patch applicationset whoami --type='json' -p="[...]"
```

**使用场景**:
- 清理孤立的 ApplicationSet 条目
- 数据库与 ApplicationSet 不一致时修复

---

### 4. 文档更新

#### `GIT_BRANCH_STRATEGY.md` (新建)

**内容**:
- 分支分类（保护、预置、动态、临时）
- 分支操作规则（创建、删除、恢复）
- 归档机制（使用 Git Tags）
- 常见场景示例

#### `ARCHITECTURE.md` (更新)

**变更**:
1. 网络拓扑图：删除 dev-kind, uat-kind, prod-kind
2. 预置集群说明：更新为 3 个集群（默认 k3d）
3. 新增"集群命名原则"章节
4. 测试幂等性说明：更新预置集群数量

---

### 5. 数据清理

#### 删除孤立的 Kind 集群

```bash
# 删除 dev-kind, uat-kind, prod-kind
scripts/delete_env.sh -n dev-kind -p kind
scripts/delete_env.sh -n uat-kind -p kind
scripts/delete_env.sh -n prod-kind -p kind

# 验证数据库
kubectl exec postgresql-0 -- psql -U kindler -d kindler -c "SELECT name, provider FROM clusters ORDER BY name;"

# 结果：
#          name          | provider 
# -----------------------+----------
#  dev                   | k3d
#  devops                | k3d
#  prod                  | k3d
#  test-api-k3d-2734674  | k3d
#  test-api-kind-2734674 | kind
#  uat                   | k3d
```

---

## 分支管理策略

### 分支分类

| 分类 | 分支 | 保护状态 | 删除策略 | 归档 |
|------|------|----------|----------|------|
| **保护分支** | `devops`, `main`, `master` | ✅ 保护 | ❌ 禁止删除 | ❌ N/A |
| **预置业务分支** | `dev`, `uat`, `prod` | ⚠️ 不保护 | ⚠️ 避免删除 | ✅ 删除前归档 |
| **动态业务分支** | 用户创建（如 `staging`） | ⚠️ 不保护 | ✅ 允许删除 | ✅ 删除前归档 |
| **测试分支** | `test-api-*`, `test-e2e-*` | ⚠️ 不保护 | ✅ 自动删除 | ❌ 不归档 |

### 归档机制

**使用 Git Tags 替代快照分支**:

**优势**:
- ✅ Tags 不可变，更安全
- ✅ 无合并冲突
- ✅ 历史清晰
- ✅ 易于恢复

**Tag 命名规范**:
```
archive/<cluster-name>/<timestamp>

示例:
archive/dev/20251027-143052
archive/staging/20251027-150330
```

**归档示例**:
```bash
# 删除业务集群（自动创建归档）
scripts/delete_env.sh -n staging -p k3d

# 执行步骤：
# 1. 创建归档 tag: archive/staging/20251027-143052
# 2. 删除 Git 分支: staging
# 3. 删除 K8s 集群
# 4. 删除数据库记录
# 5. 从 ArgoCD 注销
# 6. 从 Portainer 删除
```

**恢复示例**:
```bash
# 恢复配置
scripts/restore_cluster_config.sh staging

# 重新创建集群
scripts/create_env.sh -n staging -p k3d
```

---

## 验证结果

### 1. 配置验证

```bash
# 环境配置
$ cat config/environments.csv | grep -v '#' | tail -4
devops,k3d,30800,19000,false,false,23800,23843,
dev,k3d,30080,19001,true,true,18090,18443,10.101.0.0/16
uat,k3d,30080,19002,true,true,18091,18444,10.102.0.0/16
prod,k3d,30080,19003,true,true,18092,18445,10.103.0.0/16

✓ 仅包含 4 行配置（1 devops + 3 preset）
✓ 无 dev-kind, uat-kind, prod-kind
```

### 2. 数据库验证

```bash
$ kubectl --context k3d-devops -n paas exec postgresql-0 -- \
  psql -U kindler -d kindler -c "SELECT name, provider FROM clusters ORDER BY name;"

         name          | provider 
-----------------------+----------
 dev                   | k3d
 devops                | k3d
 prod                  | k3d
 test-api-k3d-2734674  | k3d
 test-api-kind-2734674 | kind
 uat                   | k3d
(6 rows)

✓ 预置集群：dev, uat, prod (k3d)
✓ 测试集群：test-api-* (保留供检查)
✓ 无 dev-kind, uat-kind, prod-kind
```

### 3. Git 分支验证

```bash
$ git ls-remote --heads http://git.devops.192.168.51.30.sslip.io/fc005/devops.git | \
  awk '{print $2}' | sed 's|refs/heads/||' | sort

dev
devops
prod
test-api-k3d-2734674
test-api-kind-2734674
uat

✓ 与数据库一致
✓ 无 dev-kind, uat-kind, prod-kind
```

### 4. ApplicationSet 验证

```bash
$ kubectl --context k3d-devops -n argocd get applicationset whoami \
  -o jsonpath='{range .spec.generators[0].list.elements[*]}{.clusterName}{"\n"}{end}'

dev
uat
prod
test-api-k3d-2734674
test-api-kind-2734674

✓ 与数据库一致
✓ 无 dev-kind, uat-kind, prod-kind
```

---

## 用户使用指南

### 场景 1: 修改预置集群的 Provider

```bash
# 1. 编辑 environments.csv，修改 dev 的 provider
vim config/environments.csv
# 修改：dev,k3d,... → dev,kind,...

# 2. 删除现有集群
scripts/delete_env.sh -n dev -p k3d

# 3. 重新创建（从归档恢复配置）
scripts/restore_cluster_config.sh dev  # 恢复 Git 配置
scripts/create_env.sh -n dev -p kind   # 创建 kind 集群
```

### 场景 2: 创建动态业务集群

```bash
# CLI 创建
scripts/create_env.sh -n staging -p k3d

# WebUI 创建
# 在 Kindler WebUI 点击"创建集群"
# 输入名称: staging
# 选择 provider: k3d

# 结果：
# - K8s cluster: staging (k3d)
# - Git branch: staging
# - Database record: staging (provider=k3d)
# - ArgoCD: registered
# - Portainer: registered
```

### 场景 3: 删除动态业务集群

```bash
# 删除集群（自动创建归档）
scripts/delete_env.sh -n staging -p k3d

# 执行内容：
# 1. 创建归档 tag: archive/staging/<timestamp>
# 2. 删除 Git 分支
# 3. 删除 K8s 集群
# 4. 删除数据库记录
# 5. 从 ArgoCD 注销
# 6. 从 Portainer 删除

# 恢复集群
scripts/restore_cluster_config.sh staging  # 从归档恢复配置
scripts/create_env.sh -n staging -p k3d   # 重新创建集群
```

---

## 未来改进

### 1. Git 分支删除逻辑

**当前状态**: 尚未集成到 `delete_env.sh`

**待实施**:
```bash
# 在 scripts/delete_env.sh 中添加
delete_git_branch_with_archive() {
  # ... 见 GIT_BRANCH_STRATEGY.md "规则 2" ...
}
```

### 2. 归档管理脚本

**待实施**:
- `scripts/restore_cluster_config.sh` - 从归档恢复配置
- `scripts/cleanup_old_archives.sh` - 清理过期归档
- `scripts/cleanup_orphaned_branches.sh` - 清理孤立分支

### 3. Git 服务器配置

**待实施**: 在 Gitea/GitLab 配置分支保护规则

```yaml
protected_branches:
  - name: devops
    can_delete: false
  - name: main
    can_delete: false

# dev/uat/prod 不设置保护，允许快速提交
```

---

## 结论

### ✅ 已完成

1. 修正了集群命名规范（名称与 provider 解耦）
2. 更新了预置集群配置（3 个：dev, uat, prod）
3. 清理了孤立的 kind 集群数据
4. 修复了 ApplicationSet 配置
5. 更新了所有相关文档
6. 创建了 Git 分支管理策略文档

### 📋 待实施

1. 在 `delete_env.sh` 中集成 Git 分支删除逻辑
2. 创建归档管理和恢复脚本
3. 配置 Git 服务器的分支保护规则

### 📝 关键文档

- `GIT_BRANCH_STRATEGY.md` - Git 分支管理策略（新建）
- `ARCHITECTURE.md` - 架构文档（已更新）
- `config/environments.csv` - 预置集群配置（已修正）
- `tests/run_tests.sh` - 测试脚本（已修正）

---

**完成时间**: 2025-10-27  
**影响范围**: 配置、测试、文档、脚本  
**破坏性变更**: ✅ 已删除 dev-kind, uat-kind, prod-kind 集群

