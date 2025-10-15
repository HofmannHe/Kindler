# Changelog

## [1.0.0] - 2025-10-15

### 🎉 GitOps 方案实施完成

#### ✅ 已实施功能

**应用层 GitOps（方案 A）**
- 实现基于 ArgoCD ApplicationSet 的应用管理
- 使用 List Generator 管理 11 个 whoami Applications
- 所有应用配置存储在 Git，实现配置即代码
- 启用自动同步、prune 和 selfHeal 策略

**集群注册增强**
- 为 ArgoCD 集群 Secret 添加 labels (env, provider, type)
- 添加 annotations (portainer-edge-id, portainer-edge-key)
- 从 Portainer Edge Agent Secret 读取凭证
- 支持动态凭证传递到 ApplicationSet

**基础设施 Helm Charts**
- 创建 edge-agent Helm Chart
- 创建 traefik Helm Chart
- 创建父 Chart (infrastructure)
- 支持通过 Helm values 参数化配置

**Git 分支策略**
- 为所有环境创建对应的 Git 分支
- 分支名与环境名一一对应
- 每个分支包含该环境的应用配置

**HAProxy 路由优化**
- 添加文件锁（flock）保护并发写入
- 修复域名匹配逻辑（支持完整环境名如 dev-k3d）
- 自动生成 ACL 和 backend 配置

**镜像管理**
- 导入 rancher/mirrored-pause:3.6 到所有 k3d 集群
- 导入 traefik:v3.2.3 到所有集群
- 解决 Docker Hub 网络超时问题

**Traefik 部署**
- 为所有 kind 集群部署 Traefik Ingress Controller
- 为所有 k3d 集群部署 Traefik Ingress Controller
- 修复 RBAC 权限（添加 endpointslices 权限）
- 创建 IngressClass（traefik）

**文档体系**
- `docs/GITOPS_ARCHITECTURE.md` - 完整架构文档
- `docs/IMPLEMENTATION_SUMMARY.md` - 实施总结文档
- 包含最佳实践和演进路径建议

#### 📊 验证结果

**服务可用性**: 100% (8/8 环境)
```
✅ dev (kind)       - http://whoami.kind.dev.192.168.51.30.sslip.io
✅ uat (kind)       - http://whoami.kind.uat.192.168.51.30.sslip.io
✅ prod (kind)      - http://whoami.kind.prod.192.168.51.30.sslip.io
✅ dev-k3d (k3d)    - http://whoami.k3d.dev-k3d.192.168.51.30.sslip.io
✅ uat-k3d (k3d)    - http://whoami.k3d.uat-k3d.192.168.51.30.sslip.io
✅ prod-k3d (k3d)   - http://whoami.k3d.prod-k3d.192.168.51.30.sslip.io
✅ rttr-dev (k3d)   - http://whoami.k3d.rttr-dev.192.168.51.30.sslip.io
✅ rttr-uat (k3d)   - http://whoami.k3d.rttr-uat.192.168.51.30.sslip.io
```

**ArgoCD Applications**: 11 个（全部 Synced 状态）

**集群注册**: 11 个集群（包含正确的 labels 和 annotations）

#### 🔄 可选增强项（已准备但未启用）

**基础设施 GitOps 化**
- 文件: `argocd/applicationsets/infrastructure-base.yaml`
- 状态: 已创建但未启用
- 说明: 当前脚本部署方式稳定可靠，完全 GitOps 化需要更多测试

**Matrix Generator**
- 状态: 设计完成但未实施
- 说明: 当前 List Generator 已满足需求

#### 📝 修改文件清单

**新建文件**:
- `infrastructure/Chart.yaml`
- `infrastructure/values.yaml`
- `infrastructure/charts/edge-agent/*`
- `infrastructure/charts/traefik/*`
- `argocd/applicationsets/infrastructure-base.yaml`
- `docs/GITOPS_ARCHITECTURE.md`
- `docs/IMPLEMENTATION_SUMMARY.md`
- `CHANGELOG.md`

**修改文件**:
- `scripts/argocd_register_kubectl.sh` - 添加 labels/annotations
- `scripts/haproxy_route.sh` - 文件锁 + 域名匹配修复
- `manifests/argocd/whoami-applicationset.yaml` - 修正域名配置
- `config/environments.csv` - 添加 cluster_subnet 列

#### 🎯 项目状态

**生产就绪 ✅**

---

**实施日期**: 2025-10-15  
**版本**: 1.0.0  
**作者**: Kindler GitOps Team
