# 集群稳定性改进总结

## 完成日期
2025-10-16

## 问题背景

用户反馈"清理-创建devops集群-创建业务集群-部署应用"流程无法连续三次无错完成，存在以下问题：
1. 网络配置冲突（HAProxy 固定 IP 与集群子网重叠）
2. 超时时间不足导致组件启动失败
3. Traefik 部署有问题
4. 缺少端到端测试验证

## 实施的改进

### 1. 网络架构重构 ✅

**改动文件**：
- `scripts/cluster.sh`
- `scripts/haproxy_route.sh`  
- `scripts/argocd_register_kubectl.sh`
- `scripts/bootstrap.sh`
- `scripts/clean.sh`
- `compose/infrastructure/docker-compose.yml`

**改进内容**：
- **独立子网方案**：每个 k3d 集群使用独立的 Docker 网络（`k3d-<cluster-name>`）
- **子网配置**：从 `config/environments.csv` 的 `cluster_subnet` 列读取子网配置
- **网络隔离**：
  - devops: 10.100.10.0/24
  - dev-k3d: 10.100.50.0/24
  - uat-k3d: 10.100.60.0/24
  - prod-k3d: 10.100.70.0/24
  - 其他集群: 10.100.80-250.x
  - HAProxy: 10.100.255.100 (基础设施保留段)
- **HAProxy 连接**：动态连接到各集群网络（不再使用静态共享网络）
- **网关自动计算**：从子网自动计算网关地址（.1）

### 2. 超时和重试策略增强 ✅

**改动文件**：
- `scripts/lib.sh` - `ensure_pod_running_with_preload()`
- `tools/setup/setup_devops.sh`
- `tools/setup/register_edge_agent.sh`
- `scripts/create_env.sh`

**改进内容**：
- **增加超时时间**：
  - ArgoCD 启动：180s → 600s (10分钟)
  - ArgoCD 重启：120s → 300s (5分钟)
  - Edge Agent：120s → 300s (5分钟)
  - CoreDNS：60s → 180s (3分钟)
  - Traefik：180s → 300s (5分钟)
  
- **增强重试机制**：
  - 重试次数：2次 → 5次
  - 智能等待：快速检查(2s) → 自适应(5s)
  - 指数退避：2s → 4s → 8s (有上限)
  
- **改进日志输出**：
  - 每10秒报告一次进度
  - 显示 emoji 状态指示器（✓/✗/⏳/⚠）
  - 失败时输出详细的 pod 状态和事件

### 3. Traefik 部署修复 ✅

**改动文件**：
- `scripts/traefik.sh`

**改进内容**：
- **恢复实际部署**：从空操作恢复为完整的 Traefik 部署
- **完整 RBAC**：ServiceAccount + ClusterRole + ClusterRoleBinding
- **预加载镜像**：部署前预加载到集群避免拉取超时
- **幂等性检查**：检查已存在的部署和 NodePort
- **失败重试**：超时后自动重启 pod 并再次等待
- **语法修复**：修复 `local` 关键字在非函数中使用的语法错误

### 4. 端到端测试脚本 ✅

**新文件**：
- `scripts/test_full_cycle.sh`
- `scripts/monitor_test.sh`

**功能特性**：
- **多轮迭代测试**：支持 `--iterations N` 参数（默认3次）
- **快速模式**：`--quick` 只测试2个集群（1 kind + 1 k3d）
- **完整验证**：
  - 集群节点状态（Ready）
  - Portainer 可访问性
  - ArgoCD 运行状态
  - Edge Agent 部署状态
  - Traefik Ingress Controller
  - ArgoCD 集群注册
  - HAProxy 路由
- **超时保护**：单轮最长15分钟，全局可配置超时
- **详细日志**：
  - 控制台输出：彩色状态指示
  - 文件日志：`logs/test_cycle_<timestamp>.log`
  - 进度报告：每个步骤的耗时统计
- **错误处理**：测试失败时继续下一轮（可选）

### 5. 配置文档改进 ✅

**改动文件**：
- `config/clusters.env`

**改进内容**：
- 添加详细的网络架构说明
- 子网分配建议和规划
- HAProxy 固定 IP 配置说明
- 避免冲突的最佳实践

### 6. 清理脚本增强 ✅

**改动文件**：
- `scripts/clean.sh`

**改进内容**：
- 清理所有 k3d 集群网络（`k3d-<name>`）
- 验证模式（`--verify`）检查清理完整性
- 幂等性：可重复执行无副作用

## 技术细节

### 网络拓扑变化

**之前**：
```
所有集群 → k3d-shared (10.100.0.0/16) ← HAProxy (10.100.255.100)
             └─ IP 冲突风险
```

**现在**：
```
devops → k3d-devops (10.100.10.0/24)
dev-k3d → k3d-dev-k3d (10.100.50.0/24)  
uat-k3d → k3d-uat-k3d (10.100.60.0/24)
...
HAProxy (在 infrastructure 网络) 动态连接到各集群网络
```

### 超时策略

**智能等待策略**：
1. **快速检查阶段**（0-30s）：每2秒检查一次
2. **慢速检查阶段**（30s+）：每5秒检查一次
3. **重试触发**：达到超时后预加载镜像并重启 pod
4. **指数退避**：每次重试增加基础等待时间（2s → 4s → 8s，上限8s）
5. **最大重试**：5次尝试，总计可能等待 900s (15分钟)

### 测试覆盖范围

**单轮测试包括**：
1. 完全清理环境（带验证）
2. 创建 devops 集群（ArgoCD + Portainer + HAProxy）
3. 创建业务集群（quick模式：1个kind + 1个k3d）
4. 验证所有组件状态
5. 记录耗时和结果

**三轮测试验证**：
- 幂等性：重复创建和清理无副作用
- 稳定性：连续执行无错误
- 性能：每轮耗时记录

## 验证方法

### 自动化测试
```bash
# 完整三轮测试
./scripts/test_full_cycle.sh --iterations 3 --quick

# 查看测试日志
tail -f logs/test_cycle_*.log

# 单轮测试
./scripts/test_full_cycle.sh --iterations 1
```

### 手动验证
```bash
# 1. 清理环境
./scripts/clean.sh --all --verify

# 2. 创建 devops 集群
./scripts/bootstrap.sh

# 3. 创建业务集群
./scripts/create_env.sh -n dev
./scripts/create_env.sh -n dev-k3d

# 4. 验证
kubectl get nodes --all-namespaces
kubectl --context k3d-devops get applications -n argocd
docker network ls | grep k3d
```

## 性能指标

**预期时间**（快速模式，单轮）：
- 清理环境：~5s
- 创建 devops：~100-120s
- 创建 kind 集群：~200-250s
- 创建 k3d 集群：~150-200s
- 总计：~8-12分钟

**三轮测试总时间**：~25-40分钟

## 兼容性说明

### 保留的功能
- ✅ GitOps 工作流（ArgoCD ApplicationSet）
- ✅ Edge Agent 模式（Portainer）
- ✅ 域名路由（HAProxy）
- ✅ 环境配置管理（CSV）

### 破坏性变更
- ⚠️ 不再使用全局 `k3d-shared` 网络
- ⚠️ 每个 k3d 集群需要在 CSV 中配置 `cluster_subnet`
- ⚠️ HAProxy 不再在 docker-compose.yml 中静态连接到集群网络

### 迁移指南
如果从旧版本迁移：
1. 在 `config/environments.csv` 中为所有 k3d 集群添加 `cluster_subnet` 列
2. 运行 `./scripts/clean.sh --all` 完全清理旧环境
3. 运行 `./scripts/bootstrap.sh` 创建新环境

## 已知限制

1. **kind 集群**：不支持自定义子网，使用 Docker 默认网络
2. **网络隔离**：集群间网络完全隔离，需要通过 HAProxy 或 host 网络通信
3. **测试时间**：完整三轮测试需要30-45分钟（可使用 --quick 缩短）
4. **资源需求**：每个集群独立网络会增加 Docker 网络数量

## 后续优化建议

1. **并行创建**：支持并行创建多个业务集群
2. **健康检查**：添加集群健康检查脚本
3. **自动修复**：检测到问题时自动尝试修复
4. **性能优化**：
   - 缓存常用镜像
   - 减少不必要的等待
   - 优化镜像预加载策略
5. **监控告警**：集成 Prometheus + Grafana

## 参考文档

- [集群创建脚本](../scripts/cluster.sh)
- [测试脚本](../scripts/test_full_cycle.sh)
- [网络配置](../config/environments.csv)
- [HAProxy 配置](../compose/infrastructure/haproxy.cfg)
