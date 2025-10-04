# ArgoCD 在 k3d 集群中的部署和 HAProxy 集成

## 概述

本文档描述如何在 k3d 集群中部署 ArgoCD 服务，并通过 HAProxy 进行路由暴露。

## 架构

```
用户请求 → HAProxy (23080) → k3d 节点 NodePort (30800) → ArgoCD Service → ArgoCD Pod
```

## 前提条件

- k3d 集群已创建并运行
- Docker 环境可用
- 必要的镜像已导入到 k3d 集群:
  - `nginx:alpine`

## 部署步骤

### 1. 部署 ArgoCD 服务

```bash
# 部署 ArgoCD (基于 nginx 的演示服务)
kubectl apply -f manifests/argocd/argocd-standalone.yaml

# 检查部署状态
kubectl get pods -n argocd
kubectl get svc -n argocd
```

**预期输出:**
```
NAME                            READY   STATUS    RESTARTS   AGE
argocd-server-xxxxxxxxxx-xxxxx  1/1     Running   0          30s

NAME            TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
argocd-server   NodePort   10.43.x.x      <none>        80:30800/TCP   30s
```

### 2. 创建 Ingress 资源

```bash
# 创建 Ingress
kubectl apply -f manifests/argocd/argocd-ingress.yaml

# 检查 Ingress
kubectl get ingress -n argocd
```

### 3. 配置 HAProxy 路由

HAProxy 配置文件位于 `compose/haproxy/haproxy.cfg`。

**已添加的配置:**

```haproxy
# Frontend ACL
acl host_argocd  hdr(host) -i argocd.local
use_backend be_argocd if host_argocd

# Backend 配置
backend be_argocd
  server s1 <k3d-node-ip>:30800
```

**说明:**
- `<k3d-node-ip>`: k3d 节点的 IP 地址（如 10.10.11.2）
- `30800`: ArgoCD Service 的 NodePort

### 4. 启动/重启 HAProxy

```bash
# 启动 HAProxy
docker compose -f compose/haproxy/docker-compose.yml up -d

# 或重启
docker compose -f compose/haproxy/docker-compose.yml restart

# 检查状态
docker ps --filter "name=haproxy-gw"
```

## 访问 ArgoCD

### 方式 1: 使用 curl 测试

```bash
curl -H "Host: argocd.local" http://localhost:23080
```

### 方式 2: 浏览器访问

1. 编辑 `/etc/hosts` 文件，添加:
   ```
   127.0.0.1  argocd.local
   ```

2. 浏览器访问: `http://argocd.local:23080`

## 验证

运行以下命令验证完整部署:

```bash
# 1. 检查 k3d 集群
kubectl get nodes

# 2. 检查 ArgoCD 部署
kubectl get all -n argocd

# 3. 检查 Ingress
kubectl get ingress -n argocd

# 4. 检查 HAProxy
docker logs haproxy-gw --tail 20

# 5. 测试访问
curl -H "Host: argocd.local" http://localhost:23080
```

## 故障排查

### ArgoCD Pod 未运行

```bash
# 查看 Pod 状态
kubectl get pods -n argocd

# 查看 Pod 日志
kubectl logs -n argocd -l app=argocd-server

# 查看 Pod 描述
kubectl describe pod -n argocd -l app=argocd-server
```

### 无法通过 HAProxy 访问

1. **检查 HAProxy 配置:**
   ```bash
   docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep -A5 argocd
   ```

2. **检查 HAProxy 日志:**
   ```bash
   docker logs haproxy-gw
   ```

3. **检查 k3d 节点 IP:**
   ```bash
   docker inspect k3d-final-test-server-0 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
   ```

4. **测试直接访问 NodePort:**
   ```bash
   curl http://<k3d-node-ip>:30800
   ```

### 镜像拉取失败

如果本地没有镜像，需要先下载并导入:

```bash
# 下载镜像
docker pull nginx:alpine

# 导入到 k3d 集群
k3d image import nginx:alpine -c <cluster-name>
```

## 文件位置

- **ArgoCD 部署配置**: `manifests/argocd/argocd-standalone.yaml`
- **Ingress 配置**: `manifests/argocd/argocd-ingress.yaml`
- **HAProxy 配置**: `compose/haproxy/haproxy.cfg`
- **HAProxy Compose**: `compose/haproxy/docker-compose.yml`

## 网络拓扑

```
┌──────────────┐
│   用户/浏览器  │
└──────┬───────┘
       │ Host: argocd.local
       │ Port: 23080
       ▼
┌──────────────┐
│   HAProxy    │
│   (host网络) │
└──────┬───────┘
       │ 10.10.11.2:30800
       ▼
┌──────────────┐
│  k3d 节点    │
│  NodePort    │
└──────┬───────┘
       │ ClusterIP
       ▼
┌──────────────┐
│ ArgoCD Svc   │
│ Port: 80     │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ ArgoCD Pod   │
│ nginx:alpine │
└──────────────┘
```

## 清理

如需删除 ArgoCD 部署:

```bash
# 删除 ArgoCD 资源
kubectl delete -f manifests/argocd/argocd-standalone.yaml
kubectl delete -f manifests/argocd/argocd-ingress.yaml

# 删除命名空间
kubectl delete namespace argocd

# 从 HAProxy 配置中移除 ArgoCD 路由
# 编辑 compose/haproxy/haproxy.cfg
# 然后重启 HAProxy
docker compose -f compose/haproxy/docker-compose.yml restart
```