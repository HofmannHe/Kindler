# 测试指南

## 概述

本项目使用纯 Bash 脚本实现的测试套件，覆盖服务访问、网络连通性、HAProxy 配置、集群状态和 ArgoCD 集成等方面。

## 测试结构

```
tests/
├── lib.sh              # 测试工具库（断言函数、报告生成）
├── services_test.sh    # 服务访问测试
├── network_test.sh     # 网络连通性测试
├── haproxy_test.sh     # HAProxy 配置测试
├── clusters_test.sh    # 集群状态测试
├── argocd_test.sh      # ArgoCD 集成测试
├── run_tests.sh        # 测试运行器（统一入口）
└── regression_test.sh  # 完整回归测试
```

## 快速开始

### 运行所有测试

```bash
cd /path/to/kindler
bash tests/run_tests.sh all
```

### 运行指定模块测试

```bash
# 服务访问测试
bash tests/run_tests.sh services

# 网络连通性测试
bash tests/run_tests.sh network

# HAProxy 配置测试
bash tests/run_tests.sh haproxy

# 集群状态测试
bash tests/run_tests.sh clusters

# ArgoCD 集成测试
bash tests/run_tests.sh argocd
```

### 运行完整回归测试

完整回归测试会执行：清理 → 引导 → **调和** → 验证，并确保 SQLite 与实际集群完全一致。

- 首选命令：

```bash
bash scripts/regression.sh --full
```

- 调试/局部验证可使用：

```bash
bash tests/regression_test.sh --skip-clean
bash tests/regression_test.sh --skip-bootstrap
bash tests/regression_test.sh --clusters dev,uat
bash tests/regression_test.sh --skip-smoke --skip-bats  # 仅限临时排障
```

- `scripts/reconcile.sh --from-db` 是关键步骤：它读取 SQLite `clusters` 表，并在必要时创建/删除集群（要求 ≥3 k3d 与 ≥3 kind）。日志写入 `/tmp/kindler_reconcile.log`，`RECONCILE_SUMMARY=...` JSON 会通过 stdout 暴露，便于在 PR/CI 描述中引用；默认不再追加到 `docs/TEST_REPORT.md`，如确需 Markdown 报告可显式使用报告参数或手工复制。
- `scripts/test_sqlite_migration.sh` 在 bootstrap 之后运行，确认迁移后的字段（`desired_state`、`actual_state`、`last_reconciled_at` 等）以及 `devops` 记录存在。
- `tests/regression_test.sh` 在调和后调用 `scripts/test_data_consistency.sh --json-summary` 和 `scripts/db_verify.sh --json-summary`，并利用其 JSON 输出判断漂移及记录结果。

### 数据一致性 / 数据库验证

- `scripts/test_data_consistency.sh [--json-summary]`（或 `tests/test_data_consistency.sh`）
  - 逐步验证 SQLite ↔ Kubernetes 集群 ↔ ApplicationSet ↔ Portainer ↔ ArgoCD。
  - `--json-summary` 会输出 `CONSISTENCY_SUMMARY=...`，便于 CI 或回归脚本解析。
  - 可独立运行，亦由 `tests/regression_test.sh` 的数据一致性步骤自动触发。
- `scripts/db_verify.sh [--cleanup-missing] [--json-summary]`（或 `tests/db_verify.sh`）
  - 输出 SQLite `clusters` 表与实际 kube-contexts 的对照表。
  - 退出码含义：`0`=一致、`10`=数据库记录缺少对应集群、`11`=状态漂移。`--json-summary` 会打印 `DB_VERIFY_SUMMARY=...`。
  - 使用 `--cleanup-missing` 可自动移除已删除但仍留在数据库中的业务集群记录（跳过 devops）。

## 测试模块说明

### 1. 服务访问测试 (`services_test.sh`)

验证关键服务通过 HAProxy 的可访问性：

- **ArgoCD**: 验证页面加载和 HTTP 200 状态
- **Portainer**: 验证 HTTP → HTTPS 301 跳转
- **Git 服务**: 验证 Gitea/Gogs 可访问
- **HAProxy Stats**: 验证统计页面
- **whoami 服务**: 验证所有业务集群的 whoami 应用

**预期结果**:
- ArgoCD、Portainer、Git 服务应该全部可访问
- 主要业务集群（dev、uat、prod、dev-k3d、uat-k3d、prod-k3d）的 whoami 应该可访问
- 测试集群的 whoami 可能不可访问（正常）

### 2. 网络连通性测试 (`network_test.sh`)

验证网络架构正确性：

- **HAProxy 网络连接**: 验证连接到 k3d-shared 和 infrastructure 网络
- **Portainer 网络连接**: 验证连接到正确的网络
- **devops 跨网络访问**: 验证 devops 集群连接到所有业务集群网络
- **HAProxy 连通性**: 验证 HAProxy 能 ping 通 devops 集群
- **网络隔离**: 验证业务集群使用不同的子网

**预期结果**: 所有网络连接和隔离测试应该通过

### 3. HAProxy 配置测试 (`haproxy_test.sh`)

验证 HAProxy 配置文件和路由规则：

- **配置语法**: 验证 HAProxy 配置无 ALERT 错误
- **动态路由**: 验证所有业务集群的 ACL 和 backend 配置
- **Backend 可达性**: 验证 HAProxy 能访问所有 backend IP
- **域名规则一致性**: 验证 ACL 域名模式正确
- **核心服务路由**: 验证 ArgoCD、Portainer、Git、Stats 路由配置

**预期结果**:
- 配置语法应该无错误
- 主要业务集群的路由应该全部配置正确

### 4. 集群状态测试 (`clusters_test.sh`)

验证 Kubernetes 集群健康状态：

- **节点就绪**: 验证所有节点处于 Ready 状态
- **核心组件**: 验证 kube-system namespace 中的 pods 健康
- **Edge Agent**: 验证业务集群的 Portainer Edge Agent 运行
- **whoami 应用**: 验证业务集群的 whoami 应用运行

**预期结果**:
- 所有集群的节点应该就绪
- kube-system pods 应该健康（少数辅助 pods 可能处于非 Running 状态，属正常）
- 主要业务集群的 Edge Agent 和 whoami 应该运行

### 5. ArgoCD 集成测试 (`argocd_test.sh`)

验证 ArgoCD 与集群的集成：

- **ArgoCD Server**: 验证 ArgoCD server 部署和 pod 状态
- **集群注册**: 验证所有业务集群注册到 ArgoCD
- **Git Repository**: 验证 Git 仓库连接配置
- **Application 同步**: 验证 whoami applications 的同步状态

**预期结果**:
- ArgoCD server 应该运行正常
- 主要业务集群应该注册到 ArgoCD
- 大部分 applications 应该处于 Synced 状态

## 测试工具库 (`lib.sh`)

提供以下断言函数：

- `assert_equals <expected> <actual> <description>`: 断言相等
- `assert_contains <haystack> <needle> <description>`: 断言包含
- `assert_not_contains <haystack> <needle> <description>`: 断言不包含
- `assert_http_status <expected> <url> <host> <description>`: 断言 HTTP 状态码
- `assert_success <description> <command...>`: 断言命令成功
- `assert_greater_than <threshold> <actual> <description>`: 断言大于
- `print_summary`: 打印测试摘要

## 测试输出格式

```
==========================================
Service Access Tests
==========================================

[1/5] ArgoCD Service
  ✓ ArgoCD page loads via HAProxy
  ✓ ArgoCD returns 200 OK

[2/5] Portainer Service
  ✗ Portainer redirect failed
    Expected: 301
    Actual: 200

==========================================
Test Summary
==========================================
Total:  10
Passed: 9
Failed: 1
Status: ✗ SOME FAILED
```

## 持续集成

虽然当前不包含 CI 配置，但测试脚本设计为可轻松集成到 CI/CD 流程：

```bash
# 在 CI 中运行完整回归测试
bash tests/regression_test.sh

# 检查退出码
if [ $? -eq 0 ]; then
  echo "Tests passed"
else
  echo "Tests failed"
  exit 1
fi
```

## 故障排查

### 测试失败常见原因

1. **服务不可访问**
   - 检查 HAProxy 是否运行：`docker ps --filter name=haproxy-gw`
   - 检查 HAProxy 配置：`cat compose/infrastructure/haproxy.cfg`
   - 查看 HAProxy 日志：`docker logs haproxy-gw --tail 50`

2. **网络连接失败**
   - 检查网络配置：`docker network ls`
   - 检查容器网络连接：`docker inspect haproxy-gw --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{"\n"}}{{end}}'`

3. **集群状态异常**
   - 检查集群上下文：`kubectl config get-contexts`
   - 检查节点状态：`kubectl --context <ctx> get nodes`
   - 检查 pods 状态：`kubectl --context <ctx> get pods -A`

4. **ArgoCD 集成问题**
   - 检查 ArgoCD 状态：`kubectl --context k3d-devops get pods -n argocd`
   - 查看 Application 状态：`kubectl --context k3d-devops get applications -n argocd`

## 扩展测试

### 添加新测试用例

1. 在相应的测试文件中添加测试函数
2. 使用 `assert_*` 函数进行断言
3. 确保 `total_tests`, `passed_tests`, `failed_tests` 计数器正确更新

示例：

```bash
# 在 services_test.sh 中添加新测试
echo "[6/6] New Service Test"
response=$(curl -s -m 5 "http://new-service.example.com/")
assert_contains "$response" "Expected Content" "New service responds correctly"
```

### 创建新测试模块

1. 在 `tests/` 目录创建新文件 `<module>_test.sh`
2. 引入测试库：`. "$ROOT_DIR/tests/lib.sh"`
3. 实现测试逻辑
4. 调用 `print_summary` 生成报告
5. 在 `run_tests.sh` 中添加新模块

## 最佳实践

1. **测试独立性**: 每个测试应该独立运行，不依赖其他测试的结果
2. **清晰的描述**: 断言描述应该清楚说明测试的内容
3. **适当的超时**: 使用 `-m 5` 等参数设置合理的超时时间
4. **错误信息**: 测试失败时输出足够的信息便于调试
5. **幂等性**: 测试应该可以重复运行而不影响结果

## 参考

- [快速验证脚本](../tests/quick_verify.sh): 快速验证核心服务
- [完整测试脚本](../tests/run_full_test.sh): 三轮完整测试（已有）
- [验证脚本](../tests/verify_cluster.sh): 单集群验证

## 测试哲学与分类（整合自 TESTING_GUIDELINES）

> 本章节整合了历史文档 `docs/TESTING_GUIDELINES.md` 中的核心内容，用于统一测试编写、执行和维护标准；旧文件已废弃，仅保留本指南作为唯一事实来源。

### TDD 与迭代节奏

- 推荐使用“红-绿-重构”循环组织变更：
  - Red：先写能复现问题/需求的测试，确认当前失败。
  - Green：用最小改动让测试通过，专注行为正确性。
  - Refactor：在保持测试通过的前提下整理脚本与结构。
- 在 Kindler 中，TDD 常见落点：
  - 先在 `tests/` 下写独立脚本或函数形式的测试。
  - 明确前置条件（已 bootstrap / 已有集群 / 数据库可用）。
  - 通过退出码与标准化输出（见下文）驱动 CI/回归。

### 测试金字塔与覆盖分布

- 建议分布：
  - 单元测试：约 70%，快速验证函数/脚本逻辑。
  - 集成测试：约 20%，验证组件之间的交互。
  - E2E 测试：约 10%，覆盖关键用户场景。
- 在 Kindler 中的典型映射：
  - 单元测试：如针对 `scripts/lib/*.sh` 的函数级测试。
  - 集成测试：如集群生命周期、一致性检查、 GitOps 流。
  - E2E 测试：如 WebUI 创建集群并通过 HAProxy 访问 whoami。

### 测试分类与示例

- 单元测试：
  - 不依赖外部集群/容器，仅依赖本地脚本/库。
  - 利用临时表/临时文件隔离状态，确保可重复运行。
- 集成测试：
  - 依赖 devops 集群、SQLite、HAProxy、ArgoCD 等真实组件。
  - 适用于验证 `scripts/create_env.sh`、`scripts/reconcile.sh` 等完整流程。
- E2E 测试：
  - 从 WebUI 或公开 API 出发，贯穿前端、后端、集群与路由。
  - 需要显式等待异步任务完成，并在结束时做完整清理。

## 编写测试的步骤与模板

> 如需完整 shell 模板，可参考历史 `docs/TESTING_GUIDELINES.md` 中的示例脚本，或在 `tests/` 目录内搜索 `template_test.sh` / `*_test.sh`。

1. 明确测试目标与前置条件
   - 指出要验证的行为（例如“db_insert_cluster 会写入 server_ip 字段”）。
   - 标明依赖：数据库、devops 集群、业务集群、网络等。
2. 设计 Setup / Execute / Assert / Teardown 四个阶段
   - Setup：清理残留状态、准备测试数据或临时资源。
   - Execute：调用被测脚本或函数，并捕获输出与退出码。
   - Assert：检查数据库/集群/文件/HTTP 返回码是否符合预期。
   - Teardown：删除测试集群、清理数据库记录和临时文件。
3. 使用统一的错误输出格式
   - 失败时输出：预期值、实际值、上下文、修复建议与调试命令，例如：
     ```bash
     echo "✗ Test Failed: <test_name>"
     echo "  Expected: <expected>"
     echo "  Actual:   <actual>"
     echo "  Context:  <key facts>"
     echo "  Fix:      <how to fix>"
     echo "  Debug:"
     echo "    1. <command_to_check_state>"
     echo "    2. <command_to_view_logs>"
     ```
4. 约定退出码
   - `0`：所有断言通过。
   - `1`：至少一个断言失败。
   - `2`：前置条件不满足（如数据库不可用），表示“跳过而非失败”。
   - `100+`：可用于特别严重或诊断专用错误。
5. 输出格式便于机器解析
   - 推荐使用统一前缀：
     - `[PASS] test_name (...)`
     - `[FAIL] test_name (...)`
     - `[SKIP] test_name (...)`
   - 复杂场景可按需输出 TAP/JSON，但仍需保持日志可读性。

## 测试维护与演进建议

- 定期审查：
  - 按月检查新增脚本是否已有覆盖。
  - 按季度整理冗余测试，合并重叠路径。
- 新增测试前的 checklist：
  - 能否复用现有入口（如 `tests/regression_test.sh`、`tests/run_tests.sh`）？
  - 是否可以扩展已有模块，而不是增加平行入口脚本？
  - 是否考虑将公共逻辑抽到 `tests/lib.sh` 或 `scripts/lib/*`？
- 编写新测试模块时，优先在本指南中补充说明，而不是再创建新的平行“指南”文档。
