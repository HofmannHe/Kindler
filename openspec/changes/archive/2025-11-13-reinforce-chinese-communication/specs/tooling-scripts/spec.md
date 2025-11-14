## ADDED Requirements
### Requirement: Chinese-First Communication
面向仓库贡献者的官方文档与脚本输出 MUST 默认使用中文描述，除专业术语、命令、路径、标识符外不得切换到其他语言。

#### Scenario: Documentation language guidance
- **GIVEN** 贡献者阅读 README、README_CN、openspec/AGENTS.md 或 scripts/README.md
- **WHEN** 文档描述流程、注意事项或沟通规范
- **THEN** 文本主体使用中文（专业术语保持英文原样）
- AND 明确说明“默认中文交流，专业术语保持英文”这一约定
- AND 有新的文档章节/脚本帮助输出该提醒时也遵循同样规则
