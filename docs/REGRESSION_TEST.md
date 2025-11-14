# 回归测试规范

本文档定义 Kindler 项目的回归测试流程、验收标准和测试用例。

## 目录

- [测试目标](#测试目标)
- [测试环境](#测试环境)
- [测试流程](#测试流程)
- [验收标准](#验收标准)
- [测试用例](#测试用例)
- [自动化测试](#自动化测试)

## 测试目标

### 核心目标

1. **功能完整性**: 验证所有核心功能正常工作
2. **GitOps 合规性**: 确保所有应用由 ArgoCD 管理
3. **网络连通性**: 验证 HAProxy 路由和服务访问
4. **集群管理**: 验证集群创建、删除、注册、反注册
5. **数据一致性**: 验证配置数据在 PostgreSQL 和 CSV 中的一致性

### 测试范围

- ✅ devops 集群创建和服务部署
- ✅ 业务集群创建和删除
- ✅ Portainer 集群注册和管理
- ✅ ArgoCD 集群注册和应用部署
- ✅ HAProxy 路由配置和访问
- ✅ PostgreSQL 数据管理
- ✅ GitOps 工作流
- ✅ 清理和恢复

## 测试环境

### 硬件要求

- **CPU**: 4 核心以上
- **内存**: 8GB 以上
- **磁盘**: 20GB 可用空间
- **网络**: 互联网连接（用于拉取镜像）

### 软件依赖

```bash
# 检查依赖
docker --version          # >= 20.10
k3d --version            # >= 5.0
kind --version           # >= 0.20
kubectl version --client # >= 1.28
jq --version             # >= 1.6
```

### 环境准备

```bash
# 1. 清理现有环境
./scripts/clean.sh --all

# 2. 确认清理完成
docker ps -a
k3d cluster list
kind get clusters

# 3. 确认配置文件
ls -l config/secrets.env
ls -l config/environments.csv
```

## 测试流程

### 脚本化计划（必读）

- 标准回归流程已固化在 `docs/REGRESSION_TEST_PLAN.md`，必须通过 `scripts/regression.sh --full`（或 `tests/regression_test.sh --full`）执行。  
- 若任一环节需要人工命令（kubectl/curl/UI 点击），即视为本轮回归失败，需要修复脚本或配置后重试。  
- 支持的参数（`--skip-clean`、`--skip-bootstrap`、`--clusters dev,uat`、`--skip-smoke`、`--skip-bats`）详见计划文档；仅限调试时使用，最终验收仍需无跳过的 `--full` 运行。

### Phase 1: 基础设施部署

**目标**: 验证 devops 集群和核心服务正常部署

```bash
# 1. 执行 bootstrap
time ./scripts/bootstrap.sh

# 2. 等待所有服务就绪（约 3-5 分钟）

# 3. 验证 devops 集群
kubectl --context k3d-devops get nodes
kubectl --context k3d-devops get pods -A

# 4. 验证 Portainer
curl -k -I https://portainer.devops.192.168.51.30.sslip.io

# 5. 验证 ArgoCD
curl -k -I https://argocd.devops.192.168.51.30.sslip.io

# 6. 验证 pgAdmin
curl -k -I https://pgadmin.devops.192.168.51.30.sslip.io

# 7. 验证 PostgreSQL
kubectl --context k3d-devops exec -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler -c "SELECT 1"
```

**验收标准**:
- ✅ devops 集群创建成功
- ✅ 所有 Pod 状态为 Running
- ✅ Portainer 可访问（HTTP 301 重定向，HTTPS 200）
- ✅ ArgoCD 可访问（HTTP 301 重定向，HTTPS 200）
- ✅ pgAdmin 可访问（HTTP 301 重定向，HTTPS 200）
- ✅ PostgreSQL 连接成功
- ✅ HAProxy Stats 可访问

### Phase 2: 业务集群创建

**目标**: 验证业务集群创建和自动注册

```bash
# 1. 创建 kind 集群
time ./scripts/create_env.sh -n test-kind -p kind

# 2. 验证集群状态
kubectl --context kind-test-kind get nodes
kubectl --context kind-test-kind get pods -A

# 3. 验证 Portainer 注册
# 登录 Portainer Web UI，检查 "test-kind" Edge Environment

# 4. 验证 ArgoCD 注册
kubectl --context k3d-devops -n argocd get secret cluster-test-kind

# 5. 验证 ArgoCD Applications
kubectl --context k3d-devops -n argocd get applications | grep test-kind

# 6. 等待 whoami 应用部署（约 1-2 分钟）
kubectl --context kind-test-kind get pods -l app=whoami

# 7. 验证 whoami 访问
curl -k https://whoami.kind.test-kind.192.168.51.30.sslip.io

# 8. 创建 k3d 集群
time ./scripts/create_env.sh -n test-k3d -p k3d

# 9. 重复验证步骤 2-7（替换 test-kind 为 test-k3d）
```

**验收标准**:
- ✅ 集群创建成功（kind 和 k3d）
- ✅ 所有 Pod 状态为 Running
- ✅ Portainer 中可见集群，状态为 "Connected"
- ✅ ArgoCD 中可见 cluster secret
- ✅ ArgoCD Applications 自动创建（infrastructure-*, whoami-*）
- ✅ Applications 状态为 "Synced" 和 "Healthy"
- ✅ whoami 应用可访问（HTTP 301 重定向，HTTPS 200）
- ✅ PostgreSQL 中有集群记录

### Phase 3: 业务集群删除

**目标**: 验证业务集群删除和自动反注册

```bash
# 1. 删除 kind 集群
time ./scripts/delete_env.sh test-kind

# 2. 验证集群已删除
kind get clusters | grep test-kind  # 应该为空

# 3. 验证 Portainer 反注册
# 登录 Portainer Web UI，确认 "test-kind" 不存在

# 4. 验证 ArgoCD 反注册
kubectl --context k3d-devops -n argocd get secret cluster-test-kind  # 应该报错

# 5. 验证 ArgoCD Applications 删除
kubectl --context k3d-devops -n argocd get applications | grep test-kind  # 应该为空

# 6. 验证 HAProxy 路由删除
curl -I http://192.168.51.30 -H 'Host: whoami.kind.test-kind.192.168.51.30.sslip.io'  # 应该 503

# 7. 验证 PostgreSQL 记录删除
kubectl --context k3d-devops exec -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler -c "SELECT * FROM clusters WHERE name='test-kind'"  # 应该为空

# 8. 删除 k3d 集群并重复验证
time ./scripts/delete_env.sh test-k3d
```

**验收标准**:
- ✅ 集群删除成功
- ✅ Portainer 中集群不存在
- ✅ ArgoCD 中 cluster secret 不存在
- ✅ ArgoCD Applications 不存在
- ✅ HAProxy 路由不存在（返回 503）
- ✅ PostgreSQL 中记录不存在
- ✅ kubeconfig 中 context 已清理

### Phase 4: GitOps 合规性验证

**目标**: 验证所有应用由 ArgoCD 管理

```bash
# 1. 创建测试集群
./scripts/create_env.sh -n gitops-test -p k3d

# 2. 检查 GitOps 合规性
./scripts/check_gitops_compliance.sh gitops-test

# 3. 验证 infrastructure ApplicationSet
kubectl --context k3d-devops -n argocd get applicationset infrastructure -o yaml

# 4. 验证 whoami ApplicationSet
kubectl --context k3d-devops -n argocd get applicationset whoami -o yaml

# 5. 验证 Portainer Edge Agent 由 ArgoCD 管理
kubectl --context k3d-gitops-test -n portainer-edge get deployment portainer-edge-agent -o yaml | grep -i argocd

# 6. 验证 Traefik 由 ArgoCD 管理（如果适用）
kubectl --context k3d-gitops-test -n traefik get deployment traefik -o yaml | grep -i argocd

# 7. 清理测试集群
./scripts/delete_env.sh gitops-test
```

**验收标准**:
- ✅ 所有应用有对应的 ArgoCD Application 或 ApplicationSet
- ✅ 应用配置存储在外部 Git 仓库
- ✅ 应用状态为 "Synced"
- ✅ 没有手动 `kubectl apply` 部署的资源（ArgoCD 本身除外）
- ✅ GitOps 合规性检查通过

### Phase 5: 数据管理验证

**目标**: 验证配置数据在 PostgreSQL 和 CSV 中的一致性

```bash
# 1. 创建测试集群
./scripts/create_env.sh -n db-test -p k3d

# 2. 验证 PostgreSQL 记录
kubectl --context k3d-devops exec -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler -c "SELECT name, provider, status FROM clusters WHERE name='db-test'"

# 3. 验证 CSV 记录
grep "^db-test," config/environments.csv

# 4. 修改集群配置（通过 PostgreSQL）
kubectl --context k3d-devops exec -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler -c "UPDATE clusters SET status='testing' WHERE name='db-test'"

# 5. 验证修改生效
kubectl --context k3d-devops exec -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler -c "SELECT status FROM clusters WHERE name='db-test'"

# 6. 删除集群
./scripts/delete_env.sh db-test

# 7. 验证记录删除
kubectl --context k3d-devops exec -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler -c "SELECT * FROM clusters WHERE name='db-test'"  # 应该为空
```

**验收标准**:
- ✅ 创建集群时自动添加 PostgreSQL 记录
- ✅ PostgreSQL 和 CSV 数据一致
- ✅ 可以通过 PostgreSQL 查询和修改配置
- ✅ 删除集群时自动删除 PostgreSQL 记录
- ✅ 数据库不可用时自动回退到 CSV

### Phase 6: 清理和恢复

**目标**: 验证清理和恢复功能

```bash
# 1. 创建多个测试集群
./scripts/create_env.sh -n cleanup-test-1 -p kind
./scripts/create_env.sh -n cleanup-test-2 -p k3d

# 2. 验证集群存在
kubectl config get-contexts | grep cleanup-test

# 3. 执行清理（保留 devops）
./scripts/clean.sh

# 4. 验证业务集群已删除
kind get clusters | grep cleanup-test  # 应该为空
k3d cluster list | grep cleanup-test  # 应该为空

# 5. 验证 devops 集群仍然存在
kubectl --context k3d-devops get nodes

# 6. 验证 Portainer 和 HAProxy 仍然运行
docker ps | grep portainer-ce
docker ps | grep haproxy-gw

# 7. 执行完全清理
./scripts/clean.sh --all

# 8. 验证所有内容已删除
docker ps | grep -E 'portainer|haproxy'  # 应该为空
k3d cluster list  # 应该为空
kind get clusters  # 应该为空

# 9. 快速恢复
time ./scripts/bootstrap.sh

# 10. 验证恢复成功
kubectl --context k3d-devops get pods -A
curl -k -I https://portainer.devops.192.168.51.30.sslip.io
```

**验收标准**:
- ✅ `clean.sh` 删除业务集群，保留 devops
- ✅ `clean.sh --all` 删除所有内容
- ✅ `bootstrap.sh` 可以快速恢复环境
- ✅ 恢复后所有服务正常工作

## 验收标准

### 功能验收

| 功能 | 验收标准 | 优先级 |
|------|---------|--------|
| devops 集群创建 | 所有 Pod Running，服务可访问 | P0 |
| 业务集群创建 | 集群就绪，自动注册成功 | P0 |
| 业务集群删除 | 集群删除，自动反注册成功 | P0 |
| Portainer 管理 | 可见集群，状态 Connected | P0 |
| ArgoCD 部署 | Applications Synced & Healthy | P0 |
| HAProxy 路由 | 服务可通过域名访问 | P0 |
| PostgreSQL 管理 | 配置数据正确存储和查询 | P1 |
| GitOps 合规 | 所有应用由 ArgoCD 管理 | P1 |
| 清理和恢复 | 完全清理后可快速恢复 | P1 |

### 性能验收

| 指标 | 目标 | 测量方法 |
|------|------|---------|
| bootstrap 时间 | < 5 分钟 | `time ./scripts/bootstrap.sh` |
| 创建集群时间 | < 2 分钟 | `time ./scripts/create_env.sh -n test -p k3d` |
| 删除集群时间 | < 30 秒 | `time ./scripts/delete_env.sh test` |
| 应用部署时间 | < 2 分钟 | 从 Application 创建到 Synced |
| 服务响应时间 | < 1 秒 | `curl -w "%{time_total}\n"` |

### 稳定性验收

| 场景 | 验收标准 |
|------|---------|
| 重复创建删除 | 连续 5 次创建删除无错误 |
| 并发创建 | 同时创建 2 个集群无冲突 |
| 网络中断恢复 | 断网后恢复，服务自动恢复 |
| 容器重启 | Portainer/HAProxy 重启后服务正常 |
| 集群重启 | devops 集群重启后服务正常 |

## 测试用例

### TC001: devops 集群创建

**前置条件**: 环境已完全清理

**步骤**:
1. 执行 `./scripts/bootstrap.sh`
2. 等待完成

**预期结果**:
- devops 集群创建成功
- Portainer 可访问
- ArgoCD 可访问
- pgAdmin 可访问
- PostgreSQL 可连接

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC002: kind 集群创建

**前置条件**: devops 集群已就绪

**步骤**:
1. 执行 `./scripts/create_env.sh -n tc002 -p kind`
2. 等待完成

**预期结果**:
- 集群创建成功
- Portainer 中可见
- ArgoCD 中可见
- whoami 应用可访问

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC003: k3d 集群创建

**前置条件**: devops 集群已就绪

**步骤**:
1. 执行 `./scripts/create_env.sh -n tc003 -p k3d`
2. 等待完成

**预期结果**:
- 集群创建成功
- Portainer 中可见
- ArgoCD 中可见
- whoami 应用可访问

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC004: 集群删除

**前置条件**: TC002 或 TC003 已完成

**步骤**:
1. 执行 `./scripts/delete_env.sh tc002`
2. 等待完成

**预期结果**:
- 集群删除成功
- Portainer 中不可见
- ArgoCD 中不可见
- PostgreSQL 中无记录

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC005: GitOps 合规性

**前置条件**: 至少一个业务集群已创建

**步骤**:
1. 执行 `./scripts/check_gitops_compliance.sh <cluster_name>`
2. 检查输出

**预期结果**:
- 所有应用有对应的 ArgoCD Application
- 没有手动部署的资源
- 合规性检查通过

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC006: 数据库管理

**前置条件**: devops 集群已就绪

**步骤**:
1. 创建集群 `./scripts/create_env.sh -n tc006 -p k3d`
2. 查询 PostgreSQL `SELECT * FROM clusters WHERE name='tc006'`
3. 删除集群 `./scripts/delete_env.sh tc006`
4. 再次查询 PostgreSQL

**预期结果**:
- 创建后有记录
- 删除后无记录

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC007: 清理功能

**前置条件**: 至少一个业务集群已创建

**步骤**:
1. 执行 `./scripts/clean.sh`
2. 检查集群列表

**预期结果**:
- 业务集群已删除
- devops 集群仍存在

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC008: 完全清理

**前置条件**: devops 集群已就绪

**步骤**:
1. 执行 `./scripts/clean.sh --all`
2. 检查所有资源

**预期结果**:
- 所有集群已删除
- Portainer 已停止
- HAProxy 已停止
- 数据卷已删除

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC009: 快速恢复

**前置条件**: TC008 已完成

**步骤**:
1. 执行 `./scripts/bootstrap.sh`
2. 验证所有服务

**预期结果**:
- 所有服务恢复正常
- 时间 < 5 分钟

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

### TC010: 重复创建删除

**前置条件**: devops 集群已就绪

**步骤**:
1. 循环 5 次：
   - 创建集群 `./scripts/create_env.sh -n tc010 -p k3d`
   - 删除集群 `./scripts/delete_env.sh tc010`

**预期结果**:
- 所有操作成功
- 无错误或警告

**实际结果**: _（测试时填写）_

**状态**: _（Pass/Fail）_

## 自动化测试

### 回归测试脚本

```bash
#!/usr/bin/env bash
# scripts/regression_test.sh

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
LOG_FILE="/tmp/kindler-regression-$(date +%Y%m%d-%H%M%S).log"

echo "=== Kindler Regression Test ===" | tee -a "$LOG_FILE"
echo "Start time: $(date)" | tee -a "$LOG_FILE"

# Phase 1: 完全清理
echo "[Phase 1] Cleaning environment..." | tee -a "$LOG_FILE"
"$ROOT_DIR/scripts/clean.sh" --all 2>&1 | tee -a "$LOG_FILE"

# Phase 2: 引导基础设施
echo "[Phase 2] Bootstrapping infrastructure..." | tee -a "$LOG_FILE"
time "$ROOT_DIR/scripts/bootstrap.sh" 2>&1 | tee -a "$LOG_FILE"

# Phase 3: 验证 devops 服务
echo "[Phase 3] Verifying devops services..." | tee -a "$LOG_FILE"
curl -k -I https://portainer.devops.192.168.51.30.sslip.io 2>&1 | tee -a "$LOG_FILE"
curl -k -I https://argocd.devops.192.168.51.30.sslip.io 2>&1 | tee -a "$LOG_FILE"
curl -k -I https://pgadmin.devops.192.168.51.30.sslip.io 2>&1 | tee -a "$LOG_FILE"

# Phase 4: 创建业务集群
echo "[Phase 4] Creating business clusters..." | tee -a "$LOG_FILE"
time "$ROOT_DIR/scripts/create_env.sh" -n rt-kind -p kind 2>&1 | tee -a "$LOG_FILE"
time "$ROOT_DIR/scripts/create_env.sh" -n rt-k3d -p k3d 2>&1 | tee -a "$LOG_FILE"

# Phase 5: 验证应用部署
echo "[Phase 5] Verifying application deployment..." | tee -a "$LOG_FILE"
sleep 60  # 等待应用部署
curl -k https://whoami.kind.rt-kind.192.168.51.30.sslip.io 2>&1 | tee -a "$LOG_FILE"
curl -k https://whoami.k3d.rt-k3d.192.168.51.30.sslip.io 2>&1 | tee -a "$LOG_FILE"

# Phase 6: 删除一个集群
echo "[Phase 6] Deleting one cluster..." | tee -a "$LOG_FILE"
time "$ROOT_DIR/scripts/delete_env.sh" rt-kind 2>&1 | tee -a "$LOG_FILE"

# Phase 7: 验证反注册
echo "[Phase 7] Verifying unregistration..." | tee -a "$LOG_FILE"
kubectl --context k3d-devops -n argocd get secret cluster-rt-kind 2>&1 | tee -a "$LOG_FILE" || echo "OK: secret not found"

echo "End time: $(date)" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
```

### 使用方法

```bash
# 执行完整回归测试
./scripts/regression_test.sh

# 查看测试日志
tail -f /tmp/kindler-regression-*.log

# 分析测试结果
grep -E 'PASS|FAIL|ERROR' /tmp/kindler-regression-*.log
```

## 测试报告

### 报告模板

```markdown
# Kindler 回归测试报告

**测试日期**: YYYY-MM-DD
**测试人员**: XXX
**测试环境**: 
- OS: Ubuntu 22.04
- Docker: 24.0.7
- k3d: 5.6.0
- kind: 0.20.0

## 测试结果摘要

- 总用例数: 10
- 通过: 9
- 失败: 1
- 跳过: 0

## 详细结果

| 用例 | 状态 | 耗时 | 备注 |
|------|------|------|------|
| TC001 | Pass | 4m30s | - |
| TC002 | Pass | 1m45s | - |
| TC003 | Pass | 1m20s | - |
| TC004 | Pass | 25s | - |
| TC005 | Pass | 10s | - |
| TC006 | Pass | 1m50s | - |
| TC007 | Pass | 40s | - |
| TC008 | Pass | 1m10s | - |
| TC009 | Pass | 4m20s | - |
| TC010 | Fail | - | 第3次创建失败 |

## 失败分析

### TC010: 重复创建删除

**失败原因**: 第3次创建时 Portainer Edge Agent 镜像拉取失败

**错误信息**:
```
Error: ErrImagePull
```

**解决方案**: 增加镜像预加载逻辑，确保镜像在集群创建前已存在

## 性能数据

- bootstrap 时间: 4m30s (目标 < 5m) ✅
- 创建 kind 集群: 1m45s (目标 < 2m) ✅
- 创建 k3d 集群: 1m20s (目标 < 2m) ✅
- 删除集群: 25s (目标 < 30s) ✅

## 建议

1. 优化镜像预加载逻辑
2. 添加重试机制
3. 增加超时处理

## 附件

- 测试日志: /tmp/kindler-regression-20250114-153000.log
- 截图: screenshots/
```

## Portainer Edge Agent 测试

### 测试目标

验证 Portainer Edge Agent 能够正确连接到 Portainer 服务器，确保集群在 Portainer 中显示为"健康"状态。

### 测试脚本

```bash
# 测试所有集群的 Edge Agent 连接
scripts/test_portainer_edge_agent.sh

# 测试特定集群
scripts/test_portainer_edge_agent.sh dev-k3d
scripts/test_portainer_edge_agent.sh dev
```

### 验收标准

1. **Edge Agent Pod 状态**: 所有集群的 Edge Agent Pod 必须处于 `Running` 状态
2. **连接日志**: Edge Agent 日志中不应出现 "no route to host"、"connection refused" 或 "timeout" 错误
3. **Portainer 状态**: 在 Portainer 中，集群状态应显示为健康（Status: 1）
4. **网络连通性**: Edge Agent 能够通过 HAProxy 访问 Portainer 服务器

### 故障排除

#### 常见问题

1. **"Not associated" 状态**
   - 原因: Edge Agent 无法连接到 Portainer 服务器
   - 解决: 检查 HAProxy 网络连接和 Portainer 服务器地址

2. **IP 地址变化问题**
   - 原因: Docker 网络 IP 地址动态分配
   - 解决: 使用 HAProxy 作为统一入口，避免直接使用容器 IP

3. **网络连接问题**
   - 原因: HAProxy 未连接到集群网络
   - 解决: 确保 HAProxy 连接到 `k3d-shared` 网络

#### 调试命令

```bash
# 检查 Edge Agent Pod 状态
kubectl --context k3d-dev-k3d get pods -n portainer-edge

# 检查 Edge Agent 日志
kubectl --context k3d-dev-k3d logs -n portainer-edge deployment/portainer-edge-agent --tail 50

# 检查 HAProxy 网络连接
docker inspect haproxy-gw | jq '.[0].NetworkSettings.Networks'

# 检查 Portainer 网络连接
docker inspect portainer-ce | jq '.[0].NetworkSettings.Networks'
```

## 相关文档

- [AGENTS.md](../AGENTS.md) - 项目规范
- [CLUSTER_MANAGEMENT.md](CLUSTER_MANAGEMENT.md) - 集群管理指南
- [ARCHITECTURE.md](ARCHITECTURE.md) - 架构设计
