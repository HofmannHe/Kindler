# 测试快速入门

## 快速验证

验证所有核心服务是否正常运行：

```bash
# 方式 1: 使用测试套件
bash tests/run_tests.sh services

# 方式 2: 使用快速验证脚本（更简单）
bash scripts/quick_verify.sh
```

## 完整测试

运行所有测试模块：

```bash
bash tests/run_tests.sh all
```

## 回归测试

完整的端到端测试（清理 → 引导 → 创建 → 验证）：

```bash
bash tests/regression_test.sh
```

## 测试模块

| 模块 | 命令 | 说明 |
|------|------|------|
| 服务访问 | `bash tests/run_tests.sh services` | ArgoCD、Portainer、whoami 等服务 |
| 网络连通 | `bash tests/run_tests.sh network` | 网络架构和连接性 |
| HAProxy | `bash tests/run_tests.sh haproxy` | HAProxy 配置和路由 |
| 集群状态 | `bash tests/run_tests.sh clusters` | Kubernetes 集群健康 |
| ArgoCD | `bash tests/run_tests.sh argocd` | GitOps 集成状态 |

## 详细文档

完整的测试指南请参考：[docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md)

## 测试输出示例

```
==========================================
Service Access Tests
==========================================

[1/5] ArgoCD Service
  ✓ ArgoCD page loads via HAProxy
  ✓ ArgoCD returns 200 OK

[2/5] Portainer Service
  ✓ Portainer redirects HTTP to HTTPS (301)
  ✓ Portainer redirect location is HTTPS

==========================================
Test Summary
==========================================
Total:  17
Passed: 17
Failed: 0
Status: ✓ ALL PASS
```

## 故障排查

测试失败时的常见检查点：

```bash
# 检查 HAProxy 状态
docker ps --filter name=haproxy-gw

# 检查集群状态
kubectl config get-contexts

# 查看 HAProxy 日志
docker logs haproxy-gw --tail 50

# 查看测试日志
cat data/test_suite_run.log
```

