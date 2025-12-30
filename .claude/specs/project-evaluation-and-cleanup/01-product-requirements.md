# Product Requirements Document: 项目评估与清理

## Executive Summary

本项目旨在对 Kindler 项目进行全面评估，识别并清理冗余、过时或不必要的代码、配置和文档，以提升项目的可维护性、可读性和运行效率。通过系统化的评估流程，我们将建立清晰的项目边界，优化资源使用，并为后续开发奠定更坚实的基础。

项目将分三个阶段执行：首先进行全面评估并生成报告，然后执行清理操作，最后进行验证与文档更新。预期将显著减少代码库体积，提升开发效率，并降低维护成本。

## Business Objectives

### Problem Statement

Kindler 项目在快速迭代过程中积累了大量代码、配置和文档，其中部分内容可能已经过时、冗余或不再使用。这些"技术债务"导致：
- 项目结构复杂度增加，新成员上手困难
- 维护成本上升，修改时需要考虑更多历史包袱
- 运行时资源浪费，影响性能
- 文档与实际代码不一致，造成理解偏差
- 测试覆盖率难以评估，可能存在无效测试

### Success Metrics

- **代码库体积减少**: 目标减少 15-25% 的代码行数（LOC）
- **文件数量优化**: 删除或合并至少 20% 的冗余文件
- **文档一致性**: 文档与代码一致性达到 95% 以上
- **构建时间**: 减少 10-15% 的构建/测试时间
- **维护效率**: 开发者反馈项目理解难度降低 30%（通过问卷评估）

### Expected ROI

- **短期收益**（1-2个月）：
  - 减少 20% 的代码审查时间
  - 降低 15% 的 bug 修复时间（减少误解导致的错误）
  - 提升 25% 的新功能开发速度（减少历史包袱）

- **长期收益**（6-12个月）：
  - 降低 30% 的维护成本
  - 提升团队满意度和生产力
  - 为后续重构和架构升级创造条件

## User Personas

### Primary Persona: 开发工程师（张伟）
- **Role**: 全栈开发工程师
- **Goals**:
  - 快速理解项目结构和代码逻辑
  - 高效开发新功能，避免被历史代码干扰
  - 减少因误用过时代码导致的 bug
- **Pain Points**:
  - 项目文件太多，不知道哪些是活跃使用的
  - 文档与代码不一致，经常被误导
  - 修改代码时担心影响未知的依赖关系
- **Technical Proficiency**: 高级（3-5年经验）

### Secondary Persona: DevOps 工程师（李娜）
- **Role**: 运维与基础设施工程师
- **Goals**:
  - 优化部署流程和资源使用
  - 确保环境配置清晰且可复现
  - 减少不必要的容器和服务
- **Pain Points**:
  - 配置文件过多，不确定哪些在使用
  - 部署时发现很多无用的依赖和服务
  - 难以评估资源使用的合理性
- **Technical Proficiency**: 高级（5+年经验）

### Tertiary Persona: 技术负责人（王强）
- **Role**: 技术经理/架构师
- **Goals**:
  - 控制技术债务，保持代码库健康
  - 提升团队开发效率
  - 为未来架构演进做准备
- **Pain Points**:
  - 缺乏项目健康度的量化指标
  - 难以评估清理工作的优先级和影响
  - 担心清理操作引入风险
- **Technical Proficiency**: 专家级（10+年经验）

## User Journey Maps

### Journey 1: 项目评估与报告生成
1. **Trigger**: 技术负责人决定进行项目清理
2. **Steps**:
   - 技术负责人运行评估脚本 `scripts/evaluate_project.sh`
   - 系统扫描代码库，分析文件使用情况、依赖关系、测试覆盖率
   - 系统生成详细的评估报告（Markdown 格式）
   - 技术负责人审阅报告，识别清理目标
   - 团队讨论报告内容，确定清理优先级
3. **Success Outcome**: 获得清晰的项目健康度报告，明确清理范围

### Journey 2: 执行清理操作
1. **Trigger**: 团队确认清理计划
2. **Steps**:
   - DevOps 工程师备份当前代码库（Git tag）
   - 运行清理脚本 `scripts/cleanup_project.sh --dry-run` 预览变更
   - 审查预览结果，确认无误
   - 执行实际清理 `scripts/cleanup_project.sh --execute`
   - 系统自动删除/归档标记的文件和配置
   - 运行回归测试验证系统功能
3. **Success Outcome**: 成功清理冗余内容，系统功能正常

### Journey 3: 验证与文档更新
1. **Trigger**: 清理操作完成
2. **Steps**:
   - 开发工程师运行完整测试套件
   - 验证所有核心功能正常工作
   - 更新 README 和相关文档，反映最新结构
   - 生成清理报告，记录变更内容
   - 团队 Code Review，确认变更合理
3. **Success Outcome**: 项目通过验证，文档与代码一致

## Functional Requirements

### Epic 1: 项目评估与分析

#### User Story 1.1: 代码使用情况分析
**As a** 技术负责人
**I want to** 了解哪些代码文件是活跃使用的，哪些是冗余的
**So that** 我可以做出明智的清理决策

**Acceptance Criteria:**
- [ ] 系统能扫描所有源代码文件（`.sh`, `.py`, `.yaml`, `.md` 等）
- [ ] 识别未被引用的脚本文件（通过静态分析和 Git 历史）
- [ ] 识别未被使用的配置文件（通过实际部署流程验证）
- [ ] 生成文件使用频率报告（基于 Git commit 历史）
- [ ] 标记超过 6 个月未修改的文件
- [ ] 输出格式为 Markdown 表格，包含文件路径、最后修改时间、引用次数

#### User Story 1.2: 依赖关系映射
**As a** 开发工程师
**I want to** 看到文件之间的依赖关系图
**So that** 我可以理解删除某个文件的影响范围

**Acceptance Criteria:**
- [ ] 分析脚本之间的 `source` 和函数调用关系
- [ ] 分析 Docker Compose 和 Kubernetes 配置的依赖关系
- [ ] 生成依赖关系图（文本格式或 Graphviz DOT 格式）
- [ ] 标记"孤立文件"（无入度和出度的节点）
- [ ] 标记"核心文件"（高入度的关键依赖）
- [ ] 支持按模块过滤依赖关系（如仅分析 `scripts/` 目录）

#### User Story 1.3: 测试覆盖率评估
**As a** 技术负责人
**I want to** 了解测试覆盖情况和无效测试
**So that** 我可以优化测试套件

**Acceptance Criteria:**
- [ ] 识别所有测试文件（`tests/` 目录和 `*_test.sh`）
- [ ] 分析每个测试覆盖的代码范围
- [ ] 标记未被任何测试覆盖的代码文件
- [ ] 标记测试失败或长期被跳过的测试用例
- [ ] 生成测试覆盖率报告（按模块统计）
- [ ] 建议可以删除的无效测试

#### User Story 1.4: 文档一致性检查
**As a** 开发工程师
**I want to** 知道文档与代码是否一致
**So that** 我可以信任文档内容

**Acceptance Criteria:**
- [ ] 检查 README 中提到的脚本是否存在
- [ ] 检查文档中的命令示例是否可执行
- [ ] 识别文档中引用的已删除文件
- [ ] 标记与实际代码行为不一致的文档描述
- [ ] 生成文档问题清单，包含具体位置和建议修复方式
- [ ] 支持检查多语言文档（中英文）

#### User Story 1.5: 生成评估报告
**As a** 技术负责人
**I want to** 获得一份综合评估报告
**So that** 我可以向团队展示项目现状并制定清理计划

**Acceptance Criteria:**
- [ ] 报告包含所有分析结果的汇总
- [ ] 提供量化指标（文件数、代码行数、冗余比例等）
- [ ] 按优先级排序清理建议（高/中/低）
- [ ] 包含风险评估（删除某些文件的潜在影响）
- [ ] 报告格式为 Markdown，易于分享和版本控制
- [ ] 报告保存到 `docs/PROJECT_EVALUATION_REPORT.md`

### Epic 2: 清理操作执行

#### User Story 2.1: 安全的清理预览
**As a** DevOps 工程师
**I want to** 在实际删除前预览所有变更
**So that** 我可以避免误删重要文件

**Acceptance Criteria:**
- [ ] 支持 `--dry-run` 模式，仅显示将要执行的操作
- [ ] 清晰列出将被删除的文件和原因
- [ ] 显示将被归档的文件和目标位置
- [ ] 提供交互式确认选项（`--interactive`）
- [ ] 输出变更摘要（删除 X 个文件，归档 Y 个文件）
- [ ] 支持将预览结果导出为 JSON 格式

#### User Story 2.2: 删除冗余代码文件
**As a** 开发工程师
**I want to** 自动删除已确认的冗余代码文件
**So that** 我可以减少代码库体积

**Acceptance Criteria:**
- [ ] 删除评估报告中标记为"未使用"的脚本文件
- [ ] 删除超过 12 个月未修改且无引用的文件
- [ ] 保留所有在 `CLAUDE.md` 或 `README.md` 中明确提到的文件
- [ ] 删除前自动创建 Git tag 作为备份点
- [ ] 记录所有删除操作到日志文件
- [ ] 支持通过配置文件排除特定文件（白名单）

#### User Story 2.3: 清理过时配置
**As a** DevOps 工程师
**I want to** 删除不再使用的配置文件
**So that** 我可以简化部署流程

**Acceptance Criteria:**
- [ ] 删除未被任何脚本引用的 `.env` 文件
- [ ] 删除未被使用的 Docker Compose 配置
- [ ] 删除未被使用的 Kubernetes manifests
- [ ] 合并重复的配置文件（如多个 `.env.example`）
- [ ] 更新引用路径，确保剩余配置可正常加载
- [ ] 验证清理后的配置能成功部署测试环境

#### User Story 2.4: 归档历史文件
**As a** 技术负责人
**I want to** 将不确定的文件归档而非直接删除
**So that** 我可以在需要时恢复它们

**Acceptance Criteria:**
- [ ] 创建 `archive/` 目录存放归档文件
- [ ] 归档文件保持原有目录结构
- [ ] 归档时添加时间戳和归档原因（元数据文件）
- [ ] 归档操作记录到 Git commit message
- [ ] 支持从归档恢复文件的脚本
- [ ] 归档目录不参与正常构建和测试

#### User Story 2.5: 更新依赖引用
**As a** 开发工程师
**I want to** 自动更新因清理而失效的引用
**So that** 我可以避免手动修复大量引用

**Acceptance Criteria:**
- [ ] 检测所有 `source` 语句和函数调用
- [ ] 更新指向已删除文件的引用（如果有替代文件）
- [ ] 删除指向已删除文件的无效引用
- [ ] 更新文档中的文件路径引用
- [ ] 更新测试用例中的文件路径
- [ ] 生成引用更新报告，列出所有变更

### Epic 3: 验证与文档更新

#### User Story 3.1: 回归测试验证
**As a** 开发工程师
**I want to** 运行完整的回归测试
**So that** 我可以确认清理操作未破坏功能

**Acceptance Criteria:**
- [ ] 自动运行 `scripts/regression.sh --full`
- [ ] 验证至少 3 个 kind 和 3 个 k3d 集群可正常创建
- [ ] 验证 Portainer、HAProxy、ArgoCD 功能正常
- [ ] 验证 whoami 应用可通过 GitOps 部署
- [ ] 所有测试通过率 100%（无失败或警告）
- [ ] 生成测试报告并与清理前对比

#### User Story 3.2: 性能基准对比
**As a** DevOps 工程师
**I want to** 对比清理前后的性能指标
**So that** 我可以量化清理效果

**Acceptance Criteria:**
- [ ] 测量清理前后的代码库体积（MB）
- [ ] 测量清理前后的文件数量
- [ ] 测量清理前后的构建时间
- [ ] 测量清理前后的测试执行时间
- [ ] 测量清理前后的 Docker 镜像大小
- [ ] 生成性能对比报告（表格和图表）

#### User Story 3.3: 更新项目文档
**As a** 技术负责人
**I want to** 更新所有相关文档以反映清理后的结构
**So that** 新成员可以准确理解项目

**Acceptance Criteria:**
- [ ] 更新 `README.md` 和 `README_EN.md`，删除过时内容
- [ ] 更新 `CLAUDE.md`，反映最新的项目结构
- [ ] 更新 `docs/` 目录下的所有技术文档
- [ ] 删除引用已删除文件的文档章节
- [ ] 添加清理操作的说明文档
- [ ] 确保中英文文档同步更新

#### User Story 3.4: 生成清理报告
**As a** 技术负责人
**I want to** 获得一份详细的清理报告
**So that** 我可以向团队和管理层汇报成果

**Acceptance Criteria:**
- [ ] 报告包含清理前后的对比数据
- [ ] 列出所有删除的文件和原因
- [ ] 列出所有归档的文件和位置
- [ ] 包含性能改进的量化指标
- [ ] 包含风险评估和后续建议
- [ ] 报告保存到 `docs/PROJECT_CLEANUP_REPORT.md`

#### User Story 3.5: 团队知识转移
**As a** 开发工程师
**I want to** 了解清理后的项目结构变化
**So that** 我可以快速适应新的代码库

**Acceptance Criteria:**
- [ ] 创建清理变更的 Changelog
- [ ] 提供清理前后的目录结构对比
- [ ] 记录重要文件的迁移路径
- [ ] 提供常见问题解答（FAQ）
- [ ] 组织团队分享会，讲解主要变更
- [ ] 更新开发者入门指南

## Non-Functional Requirements

### Performance
- 评估脚本在中等规模项目（1000+ 文件）上运行时间 < 5 分钟
- 清理脚本执行时间 < 2 分钟（不含测试验证）
- 回归测试时间不应因清理而增加（目标减少 10-15%）
- 报告生成时间 < 30 秒

### Security
- 清理操作前必须创建 Git tag 备份点
- 敏感配置文件（`secrets.env`）不应被误删
- 归档文件不应包含敏感信息（需脱敏）
- 所有操作需记录审计日志
- 支持回滚机制（通过 Git reset 或归档恢复）

### Usability
- 所有脚本提供 `--help` 选项，显示详细用法
- 错误信息清晰，提供具体的修复建议
- 支持详细日志模式（`--verbose`）用于调试
- 交互式模式提供友好的提示和确认
- 报告使用 Markdown 格式，易于阅读和分享

### Reliability
- 清理操作具备幂等性，可重复执行
- 异常情况下自动回滚（如测试失败）
- 关键操作前自动备份（Git tag + 归档）
- 支持断点续传（清理操作可分阶段执行）
- 所有脚本遵循 `set -Eeuo pipefail` 错误处理

### Maintainability
- 评估和清理逻辑分离，便于独立维护
- 使用配置文件管理白名单和规则
- 代码遵循项目现有的 Shell 脚本规范
- 提供单元测试覆盖核心逻辑
- 文档与代码同步更新

## Technical Constraints

### Integration Requirements
- **Git**: 依赖 Git 历史分析文件使用情况，要求 Git 2.20+
- **SQLite**: 需要访问 `kindler.db` 获取集群配置信息
- **Docker**: 需要 Docker API 检查容器和镜像使用情况
- **Kubernetes**: 需要 `kubectl` 验证 manifests 的有效性
- **Bats**: 使用 Bats 框架编写测试用例

### Technology Constraints
- 脚本必须兼容 POSIX shell（`sh`），避免 Bash 特有语法
- 支持在容器内和宿主机上执行（通过 `lib_sqlite.sh` 适配）
- 不引入新的外部依赖（如 Python 库），保持轻量级
- 遵循项目现有的目录结构和命名规范
- 所有输出使用 UTF-8 编码，支持中文

### Compliance Requirements
- 遵循 Git Flow 开发模式，在 `worktrees/` 中开发
- 使用 `KINDLER_NS` 命名空间隔离开发环境
- 清理操作不应影响 `master` 分支的稳定性
- 所有变更通过 PR 合并，经过 Code Review
- 提交信息遵循 Conventional Commits 规范

## Scope & Phasing

### MVP Scope (Phase 1): 评估与报告
**目标**: 提供项目健康度的全面评估，生成可操作的报告

**包含功能**:
- 代码使用情况分析（User Story 1.1）
- 依赖关系映射（User Story 1.2）
- 文档一致性检查（User Story 1.4）
- 生成评估报告（User Story 1.5）

**交付物**:
- `scripts/evaluate_project.sh` 评估脚本
- `docs/PROJECT_EVALUATION_REPORT.md` 评估报告模板
- 基础的依赖关系分析工具

**验收标准**:
- 能够识别至少 80% 的冗余文件
- 报告包含清晰的清理建议和优先级
- 技术负责人确认报告内容准确且可操作

### Phase 2 Enhancements: 清理执行
**目标**: 安全地执行清理操作，优化项目结构

**包含功能**:
- 安全的清理预览（User Story 2.1）
- 删除冗余代码文件（User Story 2.2）
- 清理过时配置（User Story 2.3）
- 归档历史文件（User Story 2.4）
- 更新依赖引用（User Story 2.5）

**交付物**:
- `scripts/cleanup_project.sh` 清理脚本
- `archive/` 归档目录结构
- 清理操作的配置文件（白名单、规则）

**验收标准**:
- 清理操作通过完整回归测试
- 代码库体积减少 15-25%
- 无功能性回归问题

### Phase 3 Enhancements: 验证与优化
**目标**: 验证清理效果，更新文档，建立持续优化机制

**包含功能**:
- 测试覆盖率评估（User Story 1.3）
- 回归测试验证（User Story 3.1）
- 性能基准对比（User Story 3.2）
- 更新项目文档（User Story 3.3）
- 生成清理报告（User Story 3.4）
- 团队知识转移（User Story 3.5）

**交付物**:
- `docs/PROJECT_CLEANUP_REPORT.md` 清理报告
- 更新后的 `README.md`、`CLAUDE.md` 等文档
- 性能对比数据和图表
- 团队分享材料

**验收标准**:
- 所有文档与代码一致性达到 95%+
- 团队成员反馈项目理解难度降低
- 建立定期评估机制（如季度评估）

### Future Considerations
- **自动化持续评估**: 集成到 CI/CD，每次 PR 自动评估影响
- **可视化仪表板**: 提供 Web 界面展示项目健康度指标
- **智能清理建议**: 使用机器学习预测文件的重要性
- **跨项目复用**: 将评估和清理工具抽象为通用框架
- **集成 IDE 插件**: 在开发时实时提示冗余代码

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| 误删关键文件导致功能失效 | Medium | High | 1. 强制 Git tag 备份<br>2. 完整回归测试<br>3. 归档机制而非直接删除<br>4. 白名单保护核心文件 |
| 评估结果不准确，遗漏重要依赖 | Medium | Medium | 1. 多维度分析（静态+动态+Git历史）<br>2. 人工审查评估报告<br>3. 分阶段清理，逐步验证 |
| 清理操作耗时过长，影响开发 | Low | Medium | 1. 在独立分支执行<br>2. 使用 `KINDLER_NS` 隔离<br>3. 分阶段执行，避免一次性大改 |
| 文档更新不及时，造成混乱 | Medium | Medium | 1. 清理与文档更新同步进行<br>2. PR Review 强制检查文档<br>3. 自动化文档一致性检查 |
| 团队成员不熟悉清理后的结构 | High | Low | 1. 提供详细的 Changelog<br>2. 组织知识分享会<br>3. 更新开发者入门指南<br>4. 保留归档文件供参考 |
| 清理后性能未达预期 | Low | Low | 1. 设定保守的性能目标<br>2. 清理前后性能基准对比<br>3. 如未达标可回滚 |

## Dependencies

- **Git 仓库稳定性**: 需要确保 Git 历史完整，无损坏（预计：立即可用）
- **测试套件完整性**: 依赖现有的回归测试能够覆盖核心功能（预计：立即可用）
- **团队时间投入**: 需要技术负责人和核心开发者投入时间审查报告和验证清理结果（预计：每周 4-8 小时，持续 3-4 周）
- **开发环境隔离**: 依赖 Git Worktree 和 `KINDLER_NS` 机制正常工作（预计：立即可用）
- **备份机制**: 依赖 Git tag 和归档目录作为回滚手段（预计：立即可用）

## Appendix

### Glossary
- **冗余文件**: 未被任何代码或配置引用，且长期未修改的文件
- **孤立文件**: 在依赖关系图中无入度和出度的节点，可能是独立工具或废弃代码
- **核心文件**: 被多个模块依赖的关键文件，删除风险高
- **归档**: 将文件移动到 `archive/` 目录而非直接删除，保留恢复可能性
- **幂等性**: 操作可重复执行而不产生副作用，结果一致
- **回归测试**: 验证系统核心功能未因变更而失效的测试套件
- **技术债务**: 为了快速交付而采取的次优技术决策，需要后续偿还

### References
- 项目 Git 仓库: `/home/cloud/github/hofmannhe/kindler`
- 现有文档: `CLAUDE.md`, `README.md`, `README_EN.md`
- 回归测试脚本: `scripts/regression.sh`
- 数据库访问库: `scripts/lib_sqlite.sh`
- 测试框架: Bats (Bash Automated Testing System)

---
**Document Version**: 1.0
**Date**: 2025-12-30
**Author**: Sarah (BMAD Product Owner)
**Quality Score**: 93/100
