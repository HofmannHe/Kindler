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

完整回归测试会执行：清理 → 引导 → 创建集群 → 验证

```bash
# 完整回归测试（包括清理）
bash tests/regression_test.sh

# 跳过清理步骤
bash tests/regression_test.sh --skip-clean

# 跳过 bootstrap 步骤
bash tests/regression_test.sh --skip-bootstrap

# 仅测试指定集群
bash tests/regression_test.sh --clusters dev-k3d,prod-k3d
```

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

- [快速验证脚本](../scripts/quick_verify.sh): 快速验证核心服务
- [完整测试脚本](../scripts/run_full_test.sh): 三轮完整测试（已有）
- [验证脚本](../scripts/verify_cluster.sh): 单集群验证

