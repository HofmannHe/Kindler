# WebUI 创建集群修复计划 - 参考预置集群成熟流程

## 问题分析

### 预置集群创建（成熟稳定）✅

```bash
# 在主机上执行
/home/cloud/github/hofmannhe/kindler/scripts/create_env.sh -n dev -p k3d

结果：
✅ 集群创建成功
✅ 数据库记录完整
✅ ApplicationSet 自动更新
✅ 所有服务正常
```

### WebUI 创建（不稳定）❌

```python
# 在容器内执行
await self._run_script("create_env.sh", args, ...)

问题：
❌ 容器内缺少 k3d/kind 工具（已尝试挂载但有问题）
❌ 容器内缺少完整的配置文件
❌ 执行环境与主机不一致
```

## 解决方案：让 WebUI 在主机上执行脚本

### 方案：使用主机的 docker exec 执行脚本

**核心思路**：WebUI 不在容器内执行，而是通过 docker 命令在主机上执行

```python
# cluster_service.py 修改

async def _run_script_on_host(self, script_name, args, ...):
    """在主机上执行脚本（而不是容器内）"""
    
    # 构建在主机上执行的命令
    # 通过 docker exec 在主机容器中执行，或直接在主机上执行
    
    host_script_path = f"/home/cloud/github/hofmannhe/kindler/scripts/{script_name}"
    cmd = ["bash", host_script_path] + args
    
    # 使用 docker 命令在主机上执行
    # 或使用其他主机执行机制
```

但这需要：
1. 知道主机上的脚本路径
2. 有权限在主机上执行
3. 修改 WebUI 执行机制

## 最简单的解决方案：提示用户使用脚本

由于 WebUI 容器化执行有根本性限制，最简单可靠的方案是：

### ✅ 推荐方案：禁用 WebUI 创建，提示使用脚本

```python
# webui/backend/app/api/clusters.py

@router.post("/")
async def create_cluster(...):
    # 返回提示信息
    return {
        "error": "WebUI 创建功能当前不可用",
        "message": "请使用以下命令在主机上创建集群：",
        "command": f"scripts/create_env.sh -n {cluster.name} -p {cluster.provider}"
    }
```

或在前端添加明确提示，不调用创建 API。

## 对比：为什么预置集群稳定

1. **执行环境**: 主机上有完整的 k3d/kind、docker、kubectl
2. **配置文件**: 直接访问所有配置文件
3. **权限**: 正确的用户和组权限
4. **kubeconfig**: 直接写入主机的 ~/.kube/config

## 建议

**短期**（立即）：
- 在 WebUI 前端禁用创建按钮或添加提示
- 说明：请使用 `scripts/create_env.sh` 创建集群

**中期**（如果需要 WebUI 创建）：
- 实现主机执行机制（通过队列文件或 API）
- 主机上运行守护进程读取队列并执行脚本

**长期**（重构）：
- 使用 Docker API 直接操作，不依赖命令行工具

---

**当前建议**：接受 WebUI 仅用于查看监控，创建操作使用稳定的脚本方式。

