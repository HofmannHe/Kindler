## ADDED Requirements

### Requirement: Dirty worktree review before merge
在合并到 `main` 之前，维护者 **SHALL** 对所有未提交的改动进行分类评审并关联到对应的 change-id，防止混入未知来源的脚本/文档差异。

#### Scenario: Review outstanding diffs
- **GIVEN** `git status -sb` 存在未提交的改动或未跟踪文件
- **WHEN** 维护者准备创建合并请求
- **THEN** 他们先运行 `git diff --stat`/`rg` 分类列出文档、脚本、Spec、测试与运行日志等改动
- AND 为每个类别记录处理策略（保留、拆分、丢弃或回溯到对应 change-id）
- AND 仅在所有改动都有清晰来源且通过最新 spec 校验后，才继续进入 PR 阶段。

### Requirement: Worktree-based cleanup workflow
变更梳理与测试 **MUST** 在 `worktrees/<branch>` 的隔离分支中完成，并结合 `KINDLER_NS`，以便在不污染 `main` 的前提下运行脚本/集群操作。

#### Scenario: Prepare feature worktree
- **WHEN** 维护者需要整理大量脏数据并准备合并请求
- **THEN** 他们创建 `git worktree add worktrees/<feature> feature/<feature>` 并在该目录设置 `KINDLER_NS=<feature>`
- AND 将需要保留的改动迁移到该分支，同时确保根目录 `main` 恢复干净
- AND 在新工作树中运行 `scripts/clean.sh --all`, `scripts/bootstrap.sh`, `tests/regression_test.sh --full` 等验证；通过后再依据 Conventional Commits 推送并发起 PR。

### Requirement: Completed worktrees SHALL be committed and pruned
已完成工作的 worktree **SHALL** 在改动提交后尽快删除，避免长期保留已合并或空分支的本地工作树；仅允许保留仍在开发或评审中的工作树。

#### Scenario: Worktrees cleaned after merge
- **GIVEN** 维护者通过 `git worktree list` 看到多个 `worktrees/<name>` 目录
- AND 其中某些分支已经没有未提交改动，且对应改动已在 PR/主分支中合并
- **WHEN** 维护者执行本地清理
- **THEN** 他们使用 `git worktree remove worktrees/<name>` 删除这些已完成的工作树目录
- AND 保留至少一个干净的根目录 `main` 工作树
- AND 不再出现长期指向已删除远程分支或无 diff 的“僵尸工作树`worktrees/*`”。
