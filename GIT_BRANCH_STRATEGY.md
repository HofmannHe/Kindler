# Git 分支管理策略

> 版本: 1.0  
> 更新时间: 2025-10-27

---

## 核心原则

### 1. 集群名称与 Provider 解耦

**❌ 错误示例**：
```
dev (k3d)
dev-kind (kind)    # 错误！名称包含 provider 类型
uat-kind (kind)    # 错误！
```

**✅ 正确示例**：
```
dev (provider: k3d)    # 正确！provider 是属性，不是名称
dev (provider: kind)   # 用户可修改配置切换 provider
```

### 2. 分支生命周期与集群严格绑定

```
集群创建 → Git 分支创建
集群删除 → Git 分支删除 (with archive tag)
```

### 3. 归档保护机制

**使用 Git Tags 替代快照分支**：
- 长期分支删除前创建归档 tag
- Tag 不可变，无合并冲突
- 历史清晰，易于恢复

---

## 分支分类

### 分类 1: 保护分支（Protected）

**分支**: `devops`, `main`, `master`

**特点**:
- ✅ 禁止删除
- ✅ 禁止 force-push
- ✅ 集群删除不删除分支

**用途**: 
- `devops`: 基础设施配置（PostgreSQL 等）
- `main/master`: 代码主分支

### 分类 2: 预置业务分支（Long-lived, Non-protected）

**分支**: `dev`, `uat`, `prod`

**特点**:
- ✅ 允许快速提交（支持用户开发）
- ⚠️ 避免删除（通过策略，非 Git 保护）
- ✅ 删除前创建归档 tag
- ✅ 可通过配置文件修改 provider 类型

**配置**: `config/environments.csv`
```csv
dev,k3d,30080,19001,true,true,18090,18443,10.101.0.0/16
uat,k3d,30080,19002,true,true,18091,18444,10.102.0.0/16
prod,k3d,30080,19003,true,true,18092,18445,10.103.0.0/16
```

**Provider 修改**:
```bash
# 用户想将 dev 改为 kind 类型：
# 1. 编辑 environments.csv，修改 provider 字段
dev,kind,30080,19001,true,true,18090,18443,  # 改为 kind
# 2. 重新创建集群
scripts/delete_env.sh -n dev
scripts/create_env.sh -n dev -p kind
```

### 分类 3: 动态业务分支（Long-lived, Non-protected）

**分支**: 用户通过 WebUI/CLI 创建的业务集群

**示例**: `staging`, `testing`, `feature-a`, `customer-x`

**特点**:
- ✅ 支持动态创建/删除
- ✅ 删除前创建归档 tag
- ✅ 完全由用户管理生命周期

**创建方式**:
```bash
# 方式1: CLI
scripts/create_env.sh -n staging -p k3d

# 方式2: WebUI
# 在 Kindler WebUI 点击"创建集群"
# 输入名称: staging
# 选择 provider: k3d
```

### 分类 4: 测试分支（Ephemeral）

**分支**: `test-api-*`, `test-e2e-*`

**特点**:
- ✅ 自动创建/删除
- ✅ `test-api-*`: 保留供检查
- ✅ `test-e2e-*`: 自动删除
- ❌ 不创建归档 tag（临时数据）

---

## 分支操作规则

### 规则 1: 创建分支

```bash
# 在 scripts/create_env.sh 中自动执行
create_git_branch() {
  local cluster_name="$1"
  
  # 1. 创建分支（从 devops 分支）
  git checkout devops
  git checkout -b "$cluster_name"
  
  # 2. 创建集群配置目录
  mkdir -p "whoami/"
  # ... 复制 Helm Chart 配置 ...
  
  # 3. 提交并推送
  git add .
  git commit -m "Add cluster configuration for $cluster_name"
  git push origin "$cluster_name"
}
```

### 规则 2: 删除分支（带归档）

```bash
# 在 scripts/delete_env.sh 中执行
delete_git_branch_with_archive() {
  local cluster_name="$1"
  local branch_type=$(get_branch_type "$cluster_name")
  
  case "$branch_type" in
    protected)
      echo "[GIT] ✗ Cannot delete protected branch: $cluster_name"
      return 1
      ;;
    
    long-lived)
      # 预置业务分支 或 动态业务分支
      echo "[GIT] Creating archive tag before deletion..."
      local timestamp=$(date +%Y%m%d-%H%M%S)
      local tag_name="archive/$cluster_name/$timestamp"
      
      # 创建归档 tag
      git fetch origin "$cluster_name:$cluster_name" 2>/dev/null || true
      git tag "$tag_name" "$cluster_name" -m "Archive before deletion at $timestamp"
      git push origin "$tag_name"
      
      # 删除分支
      git push origin --delete "$cluster_name"
      echo "[GIT] ✓ Branch deleted with archive: $tag_name"
      ;;
    
    ephemeral)
      if [[ "$cluster_name" =~ ^test-api- ]]; then
        echo "[GIT] ℹ Preserving test-api branch: $cluster_name"
      else
        echo "[GIT] ✓ Deleting ephemeral branch: $cluster_name (no archive)"
        git push origin --delete "$cluster_name" 2>/dev/null || true
      fi
      ;;
  esac
}

get_branch_type() {
  local name="$1"
  case "$name" in
    devops|main|master) echo "protected" ;;
    dev|uat|prod) echo "long-lived" ;;  # 预置业务分支
    test-*) echo "ephemeral" ;;
    *) echo "long-lived" ;;  # 动态创建的业务分支
  esac
}
```

### 规则 3: 恢复分支

```bash
# scripts/restore_cluster_config.sh
restore_cluster_config() {
  local cluster_name="$1"
  
  # 查找最新的归档 tag
  local latest_tag=$(git tag -l "archive/$cluster_name/*" | sort -r | head -1)
  
  if [ -z "$latest_tag" ]; then
    echo "✗ No archive found for cluster: $cluster_name"
    exit 1
  fi
  
  echo "✓ Found archive: $latest_tag"
  
  # 从 tag 恢复分支
  git fetch origin "$latest_tag"
  git checkout -b "$cluster_name" "tags/$latest_tag"
  git push origin "$cluster_name"
  
  echo "✓ Branch restored successfully"
  echo ""
  echo "Next steps:"
  echo "  1. Review the restored configuration"
  echo "  2. Re-create the cluster:"
  echo "     scripts/create_env.sh -n $cluster_name -p <k3d|kind>"
}
```

---

## 配置管理

### Git 策略配置

**文件**: `config/git_policy.env`

```bash
# Git 分支管理策略配置

# 保护分支（禁止删除）
PROTECTED_BRANCHES="devops main master"

# 预置业务分支（避免删除，但允许提交）
PRESET_BRANCHES="dev uat prod"

# 临时分支模式（自动清理）
EPHEMERAL_BRANCH_PATTERNS="test-e2e-*"

# 保留分支模式（不自动清理）
PRESERVE_BRANCH_PATTERNS="test-api-*"

# 归档策略
ARCHIVE_ENABLED=true
ARCHIVE_TAG_PREFIX="archive"
```

### Git 服务器配置

**Gitea/GitLab 分支保护规则**:

```yaml
# 仅保护 devops 和代码主分支
protected_branches:
  - name: devops
    can_delete: false
    can_force_push: false
    
  - name: main
    can_delete: false
    can_force_push: false
    require_pull_request: true  # 代码主分支需要 PR
    
  - name: master
    can_delete: false
    can_force_push: false

# dev/uat/prod 不设置保护，允许快速提交
```

---

## 归档机制

### Tag 命名规范

```
archive/<cluster-name>/<timestamp>

示例：
archive/dev/20251027-143052
archive/staging/20251027-150330
archive/customer-x/20251027-163045
```

### 归档 Tag 管理

**查看归档**:
```bash
# 查看所有归档
git tag -l "archive/*"

# 查看特定集群的归档
git tag -l "archive/dev/*"

# 查看归档详情
git show archive/dev/20251027-143052
```

**清理过期归档**:
```bash
# 保留最近 30 天的归档，删除旧归档
scripts/cleanup_old_archives.sh --days 30
```

**恢复集群配置**:
```bash
# 从最新归档恢复
scripts/restore_cluster_config.sh dev

# 从特定归档恢复
scripts/restore_cluster_config.sh dev --tag archive/dev/20251027-143052
```

---

## 实施步骤

### 步骤 1: 更新 delete_env.sh

在 `scripts/delete_env.sh` 中添加 Git 分支删除逻辑（见"规则 2"）。

### 步骤 2: 创建恢复脚本

创建 `scripts/restore_cluster_config.sh`（见"规则 3"）。

### 步骤 3: 创建清理脚本

```bash
# scripts/cleanup_orphaned_branches.sh
#!/usr/bin/env bash
# 清理孤立的 Git 分支（分支存在但集群不存在）

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/config/git.env"

echo "=========================================="
echo "  清理孤立的 Git 分支"
echo "=========================================="

# 获取所有远程分支
git fetch origin --prune

# 获取数据库中的集群列表
db_clusters=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
  psql -U kindler -d kindler -t -c "SELECT name FROM clusters;" 2>/dev/null | \
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')

# 获取所有远程业务分支（排除保护分支和特殊分支）
git_branches=$(git ls-remote --heads "$GIT_REPO_URL" | \
  awk '{print $2}' | sed 's|refs/heads/||' | \
  grep -v -E "^(devops|main|master|develop|release)$")

# 查找孤立分支
orphaned=0
for branch in $git_branches; do
  if ! echo "$db_clusters" | grep -q "^$branch$"; then
    echo "  孤立分支: $branch (集群不存在)"
    
    # 询问是否删除
    read -p "    删除此分支？(y/N): " confirm
    if [ "$confirm" = "y" ]; then
      # 创建归档（如果不是测试分支）
      if [[ ! "$branch" =~ ^test- ]]; then
        timestamp=$(date +%Y%m%d-%H%M%S)
        git fetch origin "$branch:$branch"
        git tag "archive/$branch/$timestamp" "$branch" \
          -m "Archive orphaned branch at $timestamp"
        git push origin "archive/$branch/$timestamp"
        echo "    ✓ 归档已创建: archive/$branch/$timestamp"
      fi
      
      # 删除分支
      git push origin --delete "$branch"
      echo "    ✓ 分支已删除"
      orphaned=$((orphaned + 1))
    fi
  fi
done

echo "=========================================="
echo "清理完成：删除了 $orphaned 个孤立分支"
echo "=========================================="
```

### 步骤 4: 配置 Git 服务器

在 Gitea/GitLab 中配置分支保护规则（见"Git 服务器配置"）。

### 步骤 5: 更新文档

更新 `ARCHITECTURE.md` 和 `README.md`，说明：
- 预置集群只有 dev/uat/prod（默认 k3d）
- 集群名称不耦合 provider 类型
- 用户可通过修改配置文件切换 provider
- 用户可动态创建新的业务集群

---

## 常见场景

### 场景 1: 创建新的业务集群

```bash
# 通过 CLI 创建
scripts/create_env.sh -n staging -p k3d

# 结果：
# - K8s cluster: staging (k3d)
# - Git branch: staging
# - Database record: staging (provider=k3d)
# - ArgoCD: registered
# - Portainer: registered
```

### 场景 2: 删除业务集群

```bash
# 删除集群
scripts/delete_env.sh -n staging -p k3d

# 自动执行：
# 1. 创建归档 tag: archive/staging/20251027-143052
# 2. 删除 Git 分支: staging
# 3. 删除 K8s 集群
# 4. 删除数据库记录
# 5. 从 ArgoCD 注销
# 6. 从 Portainer 删除
```

### 场景 3: 恢复已删除的集群

```bash
# 恢复配置
scripts/restore_cluster_config.sh staging

# 重新创建集群
scripts/create_env.sh -n staging -p k3d
```

### 场景 4: 修改预置集群的 Provider

```bash
# 1. 删除现有集群
scripts/delete_env.sh -n dev -p k3d

# 2. 编辑 environments.csv
# 修改 dev 行的 provider 字段：k3d → kind

# 3. 重新创建（从归档恢复配置）
scripts/restore_cluster_config.sh dev
scripts/create_env.sh -n dev -p kind
```

### 场景 5: 清理测试分支

```bash
# 自动：test-e2e-* 在测试结束后自动删除

# 手动：删除保留的 test-api-* 分支
scripts/delete_env.sh -n test-api-k3d-12345 -p k3d
# 或
tools/maintenance/cleanup_orphaned_branches.sh
```

---

## 验证命令

```bash
# 1. 查看所有集群和分支
echo "=== 数据库中的集群 ==="
kubectl --context k3d-devops -n paas exec postgresql-0 -- \
  psql -U kindler -d kindler -c "SELECT name, provider FROM clusters ORDER BY name;"

echo "=== Git 分支 ==="
git ls-remote --heads http://git.devops.192.168.51.30.sslip.io/fc005/devops.git | \
  awk '{print $2}' | sed 's|refs/heads/||' | sort

echo "=== K8s 集群 ==="
echo "k3d:"
k3d cluster list
echo "kind:"
kind get clusters

# 2. 查看归档 tags
git tag -l "archive/*" | sort

# 3. 一致性检查
scripts/check_consistency.sh
```

---

## 参考资料

- **实现脚本**:
  - `scripts/delete_env.sh` - 包含分支删除逻辑
  - `scripts/restore_cluster_config.sh` - 恢复集群配置
  - `tools/maintenance/cleanup_orphaned_branches.sh` - 清理孤立分支
  - `tools/fix_applicationset.sh` - 修复 ApplicationSet

- **配置文件**:
  - `config/environments.csv` - 预置集群配置
  - `config/git_policy.env` - Git 策略配置

- **相关文档**:
  - `ARCHITECTURE.md` - 整体架构说明
  - `TEST_FAILURE_DIAGNOSIS.md` - 测试诊断报告
