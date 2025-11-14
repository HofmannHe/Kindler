# Portainer Edge Agent 连接问题修复记录

## 问题描述

Portainer 中显示集群状态为 "Not associated"，Edge Agent 日志显示错误：
```
unable to associate Edge key | error="illegal base64 data at input byte 114"
```

## 问题根本原因

**Edge Key 的 base64 编码格式问题：**

1. **Portainer API 返回的 Edge Key 不包含末尾的 `==` 填充符**
2. **但我们在配置中添加了 `==`，导致 Edge Agent 解析失败**

### 验证过程

```bash
# Portainer API 返回的 Edge Key（不含 ==）
aHR0cDovLzEwLjEwMC4wLjc6OTAwMHwxMC4xMDAuMC43OjgwMDB8Q3djNlUxaHVpRmdRdSthaWJzUm1mbUVBUnpHMnQwK1FEbkt2b2cvbWNjZz18Mw

# 解码结果（正确）
http://10.100.0.7:9000|10.100.0.7:8000|Cwc6U1huiFgQu+aibsRmfmEARzG2t0+QDnKvog/mccg=|3

# 我们添加了 ==
aHR0cDovLzEwLjEwMC4wLjc6OTAwMHwxMC4xMDAuMC43OjgwMDB8Q3djNlUxaHVpRmdRdSthaWJzUm1mbUVBUnpHMnQwK1FEbkt2b2cvbWNjZz18Mw==

# Edge Agent 解析失败：illegal base64 data at input byte 114
```

### 测试验证

创建测试部署，使用原始的 Edge Key（不含 `==`）：

```yaml
env:
- name: EDGE_KEY
  value: "aHR0cDovLzEwLjEwMC4wLjc6OTAwMHwxMC4xMDAuMC43OjgwMDB8Q3djNlUxaHVpRmdRdSthaWJzUm1mbUVBUnzG2t0+QDnKvog/mccg=|3"
```

**结果：成功！**

日志显示：
```
[INF] edge key loaded from options
client: Connected (Latency 496.548µs)
```

## 解决方案

### 1. 更新 `manifests/argocd/infrastructure-applicationset.yaml.example`

**移除 Edge Key 末尾的 `==`：**

```yaml
- env: dev-k3d
  clusterName: dev-k3d
  provider: k3d
  portainerEdgeId: "3"
  portainerEdgeKey: "${PORTAINER_EDGE_KEY_DEV_K3D:-}"  # 注意：不含 ==
```

> ⚠️ **敏感信息管理**：`*.yaml` 正式文件已被 `.gitignore` 忽略，仅提交 `.yaml.example` 模板。真实 Edge ID/Key 通过 `scripts/argocd_register.sh` 自动写入 ArgoCD cluster Secret 的 annotations，或使用 envsubst/sops 从 `.example` 渲染。切勿在 Git 仓库中提交生成后的 `.yaml`。

### 2. 更新 `tools/setup/register_edge_agent.sh`

**直接使用 Portainer API 返回的 Edge Key，不做任何处理：**

```bash
EDGE_KEY=$(echo "$EDGE_ENV_RESPONSE" | jq -r '.EdgeKey')
# 注意：不要添加 base64 填充符 ==
```

## 关键发现

1. **Portainer Edge Key 的 base64 编码是非标准的**
   - 不包含末尾的 `==` 填充符
   - 但 Edge Agent 能够正确解析这种格式

2. **添加 `==` 会导致解析失败**
   - Edge Agent 报错 "illegal base64 data at input byte 114"
   - 这是因为 Portainer 使用了自定义的 base64 解码逻辑

3. **正确的做法**
   - 直接使用 Portainer API 返回的 Edge Key
   - 不做任何修改或格式化

## 验证步骤

```bash
# 1. 检查 Edge Agent Pod 状态
kubectl --context k3d-dev-k3d get pods -n portainer-edge

# 2. 检查 Edge Agent 日志
kubectl --context k3d-dev-k3d logs -n portainer-edge deployment/portainer-edge-agent --tail 20

# 3. 验证连接成功
# 日志应显示：
# - "edge key loaded from options"
# - "client: Connected"
# - Pod 状态应为 "Running"
```

## 未来预防

1. **不要手动修改 Portainer API 返回的 Edge Key**
2. **不要添加 base64 填充符**
3. **直接使用原始值**

## 相关文件

- `manifests/argocd/infrastructure-applicationset.yaml.example`
- `tools/setup/register_edge_agent.sh`
- `docs/REGRESSION_TEST.md`

## 修复时间

2025-10-14
