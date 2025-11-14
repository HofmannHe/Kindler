# Proposal: Reinforce Chinese-First Communication Guidance

## Why
- 本仓库在 README/AGENTS 等资料中已经强调中文沟通优先，但规格文件缺少可验证要求，后续作者可能忽略该约束。
- 需求方希望所有文档与日常交流默认中文，仅专业术语、命令、标识符保留英文，这需要落在 spec 中作为硬性约束，避免后续贡献者偏离。

## What Changes
- 在 `tooling-scripts` 规格下新增“中文优先沟通”需求，明确：文档/指引必须以中文为主（除非引用专业术语），并且贡献指南/脚本输出需提醒此约定。
- 任务完成后运行 `openspec validate --strict`，确保规格更新通过校验。

## Impact
- Specs: tooling-scripts
- Docs: README/AGENTS 等未来如需调整可引用该要求
