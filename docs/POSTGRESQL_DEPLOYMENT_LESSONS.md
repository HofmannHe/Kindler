# PostgreSQL 部署经验教训

## 问题总结

在部署 PostgreSQL 到 devops 集群的过程中，遇到了两个关键问题：

### 问题 1：local-path-provisioner helper pod 镜像拉取失败

**现象**：
- PVC 一直处于 Pending 状态
- helper pod 处于 ImagePullBackOff
- 错误信息：`failed to provision volume: create process timeout after 120 seconds`

**根本原因**：
- helper pod 需要的镜像是 `rancher/mirrored-library-busybox:1.36.1`
- 而不是通常的 `busybox:1.36.1`
- 即使 host 上有 `busybox:1.36.1`，集群内部找不到 `rancher/mirrored-library-busybox:1.36.1`

**解决方案**：
```bash
# 1. 查看实际需要的镜像（从 ConfigMap）
kubectl --context k3d-devops get configmap local-path-config -n kube-system -o yaml | grep "image:"

# 输出：image: "rancher/mirrored-library-busybox:1.36.1"

# 2. 预拉取并导入正确的镜像
docker pull rancher/mirrored-library-busybox:1.36.1
k3d image import rancher/mirrored-library-busybox:1.36.1 -c devops

# 3. 重启 provisioner
kubectl --context k3d-devops delete pod -n kube-system -l app=local-path-provisioner
```

**教训**：
- ❌ **不要假设镜像名称**：不能想当然认为是 `busybox`
- ✅ **必须查看实际配置**：从 ConfigMap 或 Pod spec 中确认实际镜像名称
- ✅ **使用完整镜像名称**：包括 registry 和完整路径

### 问题 2：PostgreSQL 镜像拉取失败

**现象**：
- PVC 已 Bound，但 Pod 处于 ErrImagePull
- PostgreSQL Pod 无法启动

**根本原因**：
- `postgres:16-alpine` 镜像虽然在 host 上存在（可能被缓存）
- 但没有导入到 k3d devops 集群内部
- k3d 集群内部的 containerd 无法访问 host 的 Docker 镜像

**解决方案**：
```bash
# 1. 预拉取镜像
docker pull postgres:16-alpine

# 2. 导入到 k3d 集群
k3d image import postgres:16-alpine -c devops

# 3. 删除 Pod 让 StatefulSet 重建
kubectl --context k3d-devops delete pod postgresql-0 -n paas
```

**教训**：
- ❌ **host 有镜像 ≠ 集群能用**：k3d 集群使用独立的 containerd
- ✅ **所有镜像都需要导入**：包括应用镜像、基础镜像、helper 镜像
- ✅ **在部署脚本中自动化**：不依赖手动干预

## 最佳实践

### 1. 镜像预拉取清单

**devops 集群基础镜像**：
```bash
# k3d 基础设施镜像
rancher/mirrored-pause:3.6
rancher/mirrored-coredns-coredns:1.12.0

# ArgoCD
quay.io/argoproj/argocd:v3.1.8

# 存储支持
rancher/local-path-provisioner:v0.0.30
rancher/mirrored-library-busybox:1.36.1

# PostgreSQL
postgres:16-alpine

# Portainer Edge Agent
portainer/agent:latest
```

**业务集群基础镜像**：
```bash
# k3d 基础设施
rancher/mirrored-pause:3.6
rancher/mirrored-coredns-coredns:1.12.0
rancher/klipper-helm:v0.9.3-build20241008
rancher/mirrored-library-traefik:2.11.18

# Portainer Edge Agent
portainer/agent:latest
```

### 2. 镜像导入标准流程

```bash
# 函数：预拉取并导入镜像
import_images_to_cluster() {
  local cluster="$1"
  shift
  local images=("$@")
  
  for img in "${images[@]}"; do
    echo "  导入 $img 到 $cluster..."
    
    # 1. 预拉取（如果本地没有）
    if ! docker images -q "$img" >/dev/null 2>&1; then
      docker pull "$img" || {
        echo "  [WARN] 预拉取失败: $img"
        continue
      }
    fi
    
    # 2. 导入到集群
    k3d image import "$img" -c "$cluster" || {
      echo "  [WARN] 导入失败: $img"
    }
  done
}
```

### 3. 验证镜像是否导入成功

```bash
# 检查集群内部的镜像
docker exec k3d-<cluster>-server-0 crictl images | grep <image-name>

# 示例
docker exec k3d-devops-server-0 crictl images | grep busybox
docker exec k3d-devops-server-0 crictl images | grep postgres
```

### 4. 调试镜像拉取问题的标准步骤

```bash
# 步骤 1：查看 Pod 状态
kubectl --context <ctx> get pods -n <namespace>

# 步骤 2：查看 Pod 描述（Events 部分）
kubectl --context <ctx> describe pod <pod-name> -n <namespace> | tail -20

# 步骤 3：查看 Pod 需要的镜像
kubectl --context <ctx> get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[*].image}'

# 步骤 4：检查镜像是否在集群内部
docker exec k3d-<cluster>-server-0 crictl images | grep <image-name>

# 步骤 5：如果镜像不存在，导入镜像
k3d image import <image> -c <cluster>

# 步骤 6：删除 Pod 让它重建
kubectl --context <ctx> delete pod <pod-name> -n <namespace>
```

## 脚本更新清单

基于这些教训，以下脚本已更新：

1. ✅ `tools/setup/setup_devops_storage.sh`：修正 busybox 镜像名称
2. ✅ `scripts/deploy_postgresql_gitops.sh`：添加 PostgreSQL 镜像预拉取
3. ✅ `scripts/bootstrap.sh`：集成存储设置和 PostgreSQL 部署

## 时间轴

- 22:12 - 开始部署 PostgreSQL
- 22:15 - 发现 PVC Pending（local-path-provisioner 超时）
- 22:18 - 尝试导入错误的 busybox 镜像
- 22:25 - 发现镜像名称不匹配
- 22:53 - 导入正确的 `rancher/mirrored-library-busybox:1.36.1`
- 22:54 - PVC 成功 Bound
- 22:54 - PostgreSQL Pod ErrImagePull
- 22:55 - 导入 postgres:16-alpine
- 22:56 - PostgreSQL 成功运行

**总耗时**：约 44 分钟（其中约 35 分钟用于排查镜像名称问题）

## 未来改进

1. **提前文档化镜像清单**：为每个组件维护完整的镜像依赖清单
2. **自动镜像发现**：从 manifests 自动提取所需镜像
3. **镜像预热脚本**：bootstrap 前批量导入所有镜像
4. **更好的错误提示**：在脚本中添加镜像检查和清晰的错误信息

