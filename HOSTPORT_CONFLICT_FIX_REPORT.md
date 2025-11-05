# 问题根因与完整修复报告

## 核心问题：hostPort冲突

### 症状
- ✅ dev集群 whoami服务正常
- ❌ uat集群 whoami服务502
- ❌ prod集群 whoami服务502

### 根因
**所有k3d集群的Traefik都配置了`hostPort: 80`**：
- dev（先创建）：占用宿主机80端口 → Traefik Running ✓
- uat（后创建）：80端口被占用 → Traefik Pending ✗
- prod（后创建）：80端口被占用 → Traefik Pending ✗

```bash
$ kubectl get pods -n traefik
# dev:  traefik-xxx  1/1  Running
# uat:  traefik-xxx  0/1  Pending  (didn't have free ports)
# prod: traefik-xxx  0/1  Pending  (didn't have free ports)
```

## 完整修复方案

### 修复1：移除Traefik的hostPort（提交: 9515d04）

**scripts/traefik.sh**:
```bash
# 旧配置（错误）
if [ "$provider" = "k3d" ]; then
  host_port_config="hostPort: 80"  # ← 多集群冲突！
fi

# 新配置（正确）
host_port_config=""  # k3d和kind都不用hostPort
```

**效果**：
- ✅ 所有集群的Traefik pods都能Running
- ❌ 但服务仍然502（因为HAProxy路由问题）

### 修复2：调整HAProxy路由逻辑（提交: 89847ea）

**scripts/haproxy_route.sh**:
```bash
# 旧架构（失败）
HAProxy → serverlb:80 → server-0:80 (hostPort被移除，无法访问)

# 新架构（成功）
HAProxy → server-0:30080 (NodePort，直接访问)
```

**代码修改**:
```bash
# 旧逻辑
serverlb_name="k3d-${name}-serverlb"
ip=$(docker inspect ... "$serverlb_name")
detected_port="80"

# 新逻辑
server_name="k3d-${name}-server-0"
ip=$(docker inspect ... "$server_name")
detected_port="$node_port"  # 30080
```

**效果**：
- ✅ 所有集群whoami服务正常访问
- ✅ HAProxy配置：10.101.0.2:30080, 10.102.0.2:30080, 10.103.0.2:30080

## 架构验证（用户约束）

### 约束要求
✅ **业务应用必须使用Ingress对外通信**
✅ **业务应用不得使用NodePort对外暴露服务**

### 实际架构
```
外部请求 (http://whoami.dev.192.168.51.30.sslip.io)
  ↓
HAProxy (haproxy-gw)
  ↓
Traefik NodePort 30080 (Ingress Controller，基础设施组件)
  ↓
Ingress 规则匹配 (ingress.networking.k8s.io/whoami)
  ↓
whoami ClusterIP Service (10.43.x.x:80，不对外)
  ↓
whoami Pod
```

### 验证结果
```bash
# whoami使用ClusterIP（不对外）
$ kubectl get svc -n whoami
whoami   ClusterIP   10.43.207.19   <none>   80/TCP

# whoami使用Ingress（通过Traefik对外）
$ kubectl get ingress -n whoami
whoami   traefik   whoami.dev.192.168.51.30.sslip.io
```

**✅ 符合用户约束！业务应用没有直接使用NodePort，只有Traefik（Ingress Controller）使用NodePort。**

## 测试结果

### 所有Traefik pods状态
```bash
$ for cluster in dev uat prod; do kubectl --context k3d-$cluster get pods -n traefik; done

# dev:  traefik-874b8cc8b-sztzr  1/1  Running
# uat:  traefik-874b8cc8b-26nvj  1/1  Running
# prod: traefik-874b8cc8b-dxzl4  1/1  Running
```
**✅ 所有Traefik pods都Running（hostPort冲突已解决）**

### 所有whoami服务访问
```bash
$ curl http://whoami.dev.192.168.51.30.sslip.io/
Hostname: whoami-775577db6f-p2rtf ✓

$ curl http://whoami.uat.192.168.51.30.sslip.io/
Hostname: whoami-775577db6f-7qch6 ✓

$ curl http://whoami.prod.192.168.51.30.sslip.io/
Hostname: whoami-775577db6f-8f8cf ✓
```
**✅ 所有whoami服务正常访问（HAProxy路由已修复）**

## 为什么之前没发现？

1. **之前可能只创建了一个k3d业务集群**（只有dev，没有uat/prod）
2. **或者每次测试前都`clean.sh --all`**（重启后dev总是第一个，占用hostPort成功）
3. **或者之前用kind集群**（kind不使用hostPort）
4. **或者dev/uat/prod是交错创建**（不是一次性创建三个）

## 相关提交

1. **ef20b20**: 网络保活规则
2. **e0ef8e1**: HAProxy网络连接幂等性
3. **be1fee2**: services_test从CSV读取provider
4. **9515d04**: 移除k3d集群Traefik的hostPort配置
5. **89847ea**: HAProxy直接访问k3d集群的NodePort

## 总结

**核心问题**：错误的设计（多集群共享hostPort）
**修复方案**：k3d和kind统一使用NodePort（简单、统一、避免冲突）
**架构优化**：减少一层转发（serverlb），提升性能
**约束验证**：业务应用仍使用Ingress，符合用户要求 ✓

