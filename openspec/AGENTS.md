# OpenSpec 指南（Kindler 项目）

> 本文件面向参与 Kindler 项目的 AI/人类贡献者。除专业术语、命令、文件路径、API 名称外，说明文本一律使用中文。

## TL;DR 快速清单
- 先运行 `openspec list` / `openspec list --specs`，了解当前变更与能力。
- 若需找需求文本，用 `rg` 搜索 `openspec/specs`（匹配 `Requirement` / `Scenario`）。
- 需要新功能或破坏性调整 → 新建 `change-id`（kebab case，动词开头，如 `add-…`）。
- 脚手架：`proposal.md`（Why/What/Impact）、`tasks.md`（清单）、可选 `design.md`、以及 `specs/<capability>/spec.md` delta。
- 变更文件编写完毕后跑 `openspec validate <id> --strict`，通过后再实现或归档。
- 未获批准不要实现；实现完成前，不要把 `tasks.md` 标记为 `[x]`。

## 三阶段流程

### Stage 1：创建变更
- 触发条件：新增功能、架构/安全/性能重构、破坏性接口调整等。
- 流程：
  1. 阅读 `openspec/project.md`、`openspec list (--specs)`、关联变更，避免重复。
  2. 选定唯一 `change-id` 创建目录：`openspec/changes/<id>/`。
  3. 填写 `proposal.md`（Why / What Changes / Impact）。
  4. 如有必要，补充 `design.md`（抉择、数据流、失败处理）。
  5. 在 `specs/<capability>/spec.md` 使用 `## ADDED|MODIFIED|REMOVED Requirements` + 至少一个 `#### Scenario`。
  6. 执行 `openspec validate <id> --strict`，修复错误后再提交审批。

### Stage 2：实现变更
在实施阶段按顺序执行以下 TODO：
1. 阅读 `proposal.md` → 明确动机与范围。
2. 阅读 `design.md`（若存在）。
3. 阅读 `tasks.md` → 获得步骤清单。
4. 按顺序实现每个任务，保持最小改动原则。
5. 确认每项验收条件完成，再把对应条目改成 `- [x]`。
6. 任务全部完成后补充测试/文档，并再次运行 `openspec validate <id> --strict`。

### Stage 3：归档变更
- 代码上线后，将 `openspec/changes/<id>` 移入 `openspec/changes/archive/<yyyy-mm-dd-id>/`。
- 运行 `openspec archive <id> --yes`（工具会自动移动目录并刷新 specs）。
- 如只改 tooling（不触发 specs），可加 `--skip-specs`，但请在提交流程中说明原因。
- 归档结束后执行 `openspec validate --specs --strict`，确认现网规格自洽。

## 上手前必须完成的检查
- 阅读 `openspec/specs/<capability>/spec.md`，确认需求是否已经覆盖。
- 通过 `openspec list` 查看仍在进行的变更，避免冲突。
- 查阅 `openspec/project.md` 获取编码/命名/测试约定。
- 若需求含糊，先向提出者确认，再决定是否需要新的 proposal。

## 搜索与调试技巧
- 列出全部 specs：`openspec spec list --long` / `--json`。
- 查看某个 spec/变更详情：`openspec show <id> [--type spec|change] [--json --deltas-only]`。
- 全文搜索需求/场景：`rg -n "Requirement:|Scenario:" openspec/specs`。
- 调试 delta 解析：`openspec change show <id> --json --deltas-only`。

## CLI 速查表
```bash
openspec list                     # 活跃变更
openspec list --specs             # 已发布规格
openspec show <item>              # 查看变更或规格
openspec validate <item> --strict # 校验（变更或规格）
openspec archive <id> --yes       # 归档（会更新 specs）
```
常用参数：
- `--json`：机器可读输出
- `--type change|spec`：消除歧义
- `--strict`：严格校验所有约束
- `--no-interactive`：禁用交互
- `--skip-specs`：归档时跳过 specs（仅限工具型改动）
- `--yes/-y`：跳过确认

## 目录结构速览
```
openspec/
├── project.md                 # 项目约定（中文）
├── specs/<capability>/        # 真实需求（已发布）
│   └── spec.md / design.md
├── changes/<change-id>/       # 提案目录
│   ├── proposal.md            # Why / What / Impact
│   ├── tasks.md               # 实施清单
│   ├── design.md              # 可选设计笔记
│   └── specs/<capability>/    # Delta（ADDED/MODIFIED/…）
└── changes/archive/...        # 已完成变更
```

## 何时需要提案？
```
新需求？
├─ 仅修复现有规格行为 → 直接修复
├─ 拼写/格式/注释 → 直接修复
├─ 依赖更新（非破坏） → 直接更新
└─ 其他（功能、架构、安全、模糊请求） → 创建 proposal
```

## Proposal 模板要点
1. 目录名 `changes/<change-id>/`，`change-id` 必须唯一、动词开头。
2. `proposal.md`：
   - `## Why` 说明痛点、约束、失败案例。
   - `## What Changes` 细化预期改动。
   - `## Impact` 罗列受影响的 specs/代码/测试。
3. `tasks.md`：编号 + Markdown checklist，实施完再勾选。
4. `design.md`（可选）：记录方案取舍、数据流、失败处理。
5. Delta：`specs/<capability>/spec.md` 使用 `## ADDED|MODIFIED|REMOVED Requirements`，每个 Requirement 至少有一个 `#### Scenario`，描述 GIVEN/WHEN/THEN。

## 实施期的最佳实践
- 做之前先把 `tasks.md` 转成 TODO 计划，避免漏项。
- 代码改动保持最小；遇到阻塞先更新 proposal/设计文档。
- 任何时候若发现未获批准的改动，请暂停并询问提出者。

## 归档后的要求
- 运行 `openspec archive <id> --yes` 后，确认 specs 目录发生预期 diff。
- `openspec validate --specs --strict` 必须通过。
- 需要对其它团队传达时，可用 `openspec show <id>` 导出 JSON/Markdown。

## 错误处理
- `openspec validate` 报错：先查看 JSON 输出，确认是缺少 Requirements、Scenario 还是拼写问题。
- 与现有变更冲突：用 `openspec list` 找到相关负责人，视情况合并或拆分。
- 缺少上下文：回到 `openspec/project.md` 或对应 spec；仍不明确就提问。

保持中文为主，命令/路径保持英文，有助于减少歧义并贴合 Kindler 的“中文优先沟通”规范。
