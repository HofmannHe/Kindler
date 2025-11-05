# GitHub 推送指南

## 当前状态

**本地 main**: 领先 origin/main 99 个提交（含刚才的文档更新）

**主要变更**:
1. SQLite 迁移（移除 PostgreSQL）
2. 声明式架构（WebUI + Reconciler）
3. HAProxy 稳定性修复
4. WebUI 功能完善
5. 测试完善（包含幂等性）
6. 文档更新

**测试状态**: ✅ 通过完整回归测试

---

## 推送步骤

### 选项A: 直接推送（如果有权限）

```bash
# 1. 最后检查
git log origin/main..main --oneline | head -20

# 2. 推送
git push origin main

# 3. 验证
git log origin/main..main  # 应该为空
```

### 选项B: 通过 PR（推荐）

```bash
# 1. 创建新分支用于 PR
git push origin main:refs/heads/sqlite-migration-and-improvements

# 2. 在 GitHub 创建 PR
# main-update → main

# 3. PR 合并后更新本地
git fetch origin
git reset --hard origin/main
```

---

## 远端分支清理（推送后）

```bash
# 清理已合并的远端分支
git push origin --delete develop
git push origin --delete feature/opt-haproxy-batch
```

---

## Worktree 清理（可选）

如需清理本地 worktrees:

```bash
git worktree remove worktrees/develop
git worktree remove worktrees/feature-ns
git worktree remove worktrees/feature-docs

# 然后删除分支
git branch -D develop
git branch -D feature/ns
git branch -D feature/docs
```

---

## 注意事项

1. GitHub main 分支可能是 protected，需要通过 PR
2. 推送前确保测试通过
3. 大量提交建议创建详细的 PR 描述

