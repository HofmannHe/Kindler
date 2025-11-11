# 集群管理指南

本文档描述 Kindler 项目的集群管理策略、操作流程和故障排查方法。

## 目录

- [集群类型](#集群类型)
- [devops 集群管理](#devops-集群管理)
- [业务集群管理](#业务集群管理)
- [集群配置管理](#集群配置管理)
- [故障排查](#故障排查)

## 集群类型

### devops 集群（管理集群）

**用途**: 运行管理工具和 PaaS 服务
- **Portainer CE**: 容器和集群统一管理
- **HAProxy**: 统一网络入口
- **ArgoCD**: GitOps CD 工具
- **PostgreSQL**: 集群配置数据库
- **pgAdmin**: 数据库管理界面

**特点**:
- 使用 k3d 部署（内置 Traefik Ingress Controller）
- 默认不清理，需要 `clean.sh --all` 才会删除
- 存储所有业务集群的配置和状态
- 通常保持运行状态

### 业务集群

**用途**: 运行实际应用（如 whoami 示例应用）

**特点**:
- 支持 kind 和 k3d 两种 provider
- 按需创建和删除
- 自动注册到 Portainer（Edge Agent 模式）
- 自动注册到 ArgoCD（kubectl 方式）
- 应用通过 GitOps 自动部署

## devops 集群管理

### 创建 devops 集群

```bash
# 完整引导（包括 Portainer、HAProxy、ArgoCD、PaaS 服务）
./scripts/bootstrap.sh
```

**bootstrap.sh 执行流程**:
1. 检查依赖工具（docker, k3d, kubectl, jq 等）
2. 加载配置（`config/clusters.env`, `config/secrets.env`）
3. 启动 Portainer 和 HAProxy（Docker Compose）
4. 创建 devops k3d 集群
5. 部署 ArgoCD
6. 部署 PaaS 服务（PostgreSQL, pgAdmin）
7. 配置 HAProxy 路由
8. 验证所有服务就绪

### 访问 devops 服务

| 服务 | HTTP | HTTPS | 凭证 |
|------|------|-------|------|
| Portainer | http://portainer.devops.192.168.51.30.sslip.io | https://portainer.devops.192.168.51.30.sslip.io | admin / `config/secrets.env` |
| ArgoCD | http://argocd.devops.192.168.51.30.sslip.io | https://argocd.devops.192.168.51.30.sslip.io | admin / `config/secrets.env` |
| pgAdmin | http://pgadmin.devops.192.168.51.30.sslip.io | https://pgadmin.devops.192.168.51.30.sslip.io | admin@kindler.local / AdminAdmin12345 |
| HAProxy Stats | http://haproxy.devops.192.168.51.30.sslip.io/stat | - | - |

**注意**: HTTP 访问会自动重定向到 HTTPS（由 HAProxy 处理）

### 清理 devops 集群

```bash
# 默认：保留 devops 集群
./scripts/clean.sh

# 完全清理（包括 devops 集群）
./scripts/clean.sh --all
# 或
./scripts/clean.sh --include-devops
```

**清理范围**:
- `clean.sh`: 删除所有业务集群，保留 devops、Portainer、HAProxy
- `clean.sh --all`: 删除所有内容，包括 devops 集群、Portainer、HAProxy、数据卷

## 业务集群管理

### 创建业务集群

```bash
# 基本用法
./scripts/create_env.sh -n <cluster_name> -p <kind|k3d>

# 示例：创建 kind 集群
./scripts/create_env.sh -n dev -p kind

# 示例：创建 k3d 集群
./scripts/create_env.sh -n dev-k3d -p k3d

# 高级选项
./scripts/create_env.sh -n test \
  -p k3d \
  --node-port 30080 \
  --pf-port 19100 \
  --register-portainer \
  --haproxy-route \
  --register-argocd
```

**参数说明**:
- `-n <name>`: 集群名称（必需）
- `-p <provider>`: 集群类型，`kind` 或 `k3d`（默认从 CSV 读取）
- `--node-port <port>`: Traefik NodePort（默认 30080）
- `--pf-port <port>`: kubectl port-forward 端口
- `--register-portainer`: 注册到 Portainer（默认启用）
- `--no-register-portainer`: 不注册到 Portainer
- `--haproxy-route`: 添加 HAProxy 路由（默认启用）
- `--no-haproxy-route`: 不添加 HAProxy 路由
- `--register-argocd`: 注册到 ArgoCD（默认启用）
- `--no-register-argocd`: 不注册到 ArgoCD

**自动化操作**:
1. 创建 k3d/kind 集群
2. 预加载必需镜像（portainer/agent:latest 等）
3. 等待集群就绪（CoreDNS Running）
4. 注册到 Portainer（Edge Agent 模式）
5. 注册到 ArgoCD（kubectl 方式）
6. 添加 HAProxy 路由
7. 同步 ArgoCD ApplicationSet（自动部署 whoami 应用）

### 删除业务集群

```bash
# 删除指定集群
./scripts/delete_env.sh <cluster_name>

# 示例
./scripts/delete_env.sh dev
./scripts/delete_env.sh dev-k3d
```

**自动化操作**:
1. 从 Portainer 反注册（删除 Edge Environment）
2. 从 ArgoCD 反注册（删除 cluster secret 和 Applications）
3. 从 HAProxy 移除路由
4. 从 CSV 配置文件移除记录
5. 从 PostgreSQL 删除记录（如果数据库可用）
6. 删除 k3d/kind 集群
7. 清理 kubeconfig context

### 停止/启动业务集群

```bash
# 停止集群（保留配置）
./scripts/cluster.sh stop <cluster_name>

# 启动已停止的集群
./scripts/cluster.sh start <cluster_name>
```

**注意**: 停止集群会释放资源，但保留配置。启动后需要重新注册到 Portainer 和 ArgoCD。

### 访问业务集群应用

业务集群的应用通过 HAProxy 统一入口访问，域名格式：

```
{service}.{cluster_type}.{env}.{BASE_DOMAIN}
```

**示例**:
- `whoami.kind.dev.192.168.51.30.sslip.io` - dev 集群（kind）的 whoami 应用
- `whoami.k3d.dev-k3d.192.168.51.30.sslip.io` - dev-k3d 集群（k3d）的 whoami 应用

**验证访问**:
```bash
# HTTP（自动重定向到 HTTPS）
curl -I http://whoami.kind.dev.192.168.51.30.sslip.io

# HTTPS
curl -k https://whoami.kind.dev.192.168.51.30.sslip.io
```

## 集群配置管理

### 配置存储

集群配置支持两种存储方式（优先级：PostgreSQL > CSV）：

1. **PostgreSQL 数据库**（推荐）
   - 位置：devops 集群的 `paas` namespace
   - 表：`clusters`
   - 自动同步：创建/删除集群时自动更新

2. **CSV 文件**（备份/回退）
   - 位置：`config/environments.csv`
   - 格式：`env,provider,node_port,pf_port,register_portainer,haproxy_route,http_port,https_port`

### 配置字段说明

| 字段 | 说明 | 示例 |
|------|------|------|
| env | 环境名称（集群名称） | dev, uat, prod, dev-k3d |
| provider | 集群类型 | kind, k3d |
| node_port | Traefik NodePort | 30080 |
| pf_port | kubectl port-forward 端口 | 19001 |
| register_portainer | 是否注册到 Portainer | true, false |
| haproxy_route | 是否添加 HAProxy 路由 | true, false |
| http_port | HTTP 暴露端口（可选） | 18090 |
| https_port | HTTPS 暴露端口（可选） | 18443 |

### CSV 到数据库迁移

```bash
# 一次性迁移所有 CSV 配置到 PostgreSQL
./tools/db/migrate_csv_to_db.sh
```

**注意**: 迁移后会自动备份 CSV 文件为 `config/environments.csv.bak`

### 数据库查询

```bash
# 连接到 PostgreSQL
kubectl --context k3d-devops exec -it -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler

# 查询所有集群
SELECT name, provider, status, created_at FROM clusters;

# 查询特定集群
SELECT * FROM clusters WHERE name = 'dev';
```

## 故障排查

### devops 集群问题

#### Portainer 无法访问

**症状**: `https://portainer.devops.192.168.51.30.sslip.io` 无法访问

**排查步骤**:
```bash
# 1. 检查 Portainer 容器状态
docker ps | grep portainer-ce

# 2. 检查 HAProxy 状态
docker ps | grep haproxy-gw

# 3. 检查 HAProxy 日志
docker logs haproxy-gw

# 4. 检查 HAProxy 配置
cat compose/infrastructure/haproxy.cfg | grep -A5 "host_portainer"

# 5. 重启服务
docker compose -f compose/infrastructure/docker-compose.yml restart
```

#### ArgoCD 无法访问

**症状**: `https://argocd.devops.192.168.51.30.sslip.io` 无法访问

**排查步骤**:
```bash
# 1. 检查 ArgoCD 服务状态
kubectl --context k3d-devops -n argocd get pods

# 2. 检查 ArgoCD Ingress
kubectl --context k3d-devops -n argocd get ingress

# 3. 检查 Traefik 日志
kubectl --context k3d-devops -n kube-system logs -l app.kubernetes.io/name=traefik

# 4. 检查 HAProxy 路由
curl -I http://192.168.51.30 -H 'Host: argocd.devops.192.168.51.30.sslip.io'

# 5. 重启 ArgoCD server
kubectl --context k3d-devops -n argocd rollout restart deployment argocd-server
```

#### PostgreSQL 无法连接

**症状**: 数据库操作失败

**排查步骤**:
```bash
# 1. 检查 PostgreSQL Pod 状态
kubectl --context k3d-devops -n paas get pods -l app.kubernetes.io/name=postgresql

# 2. 检查 PostgreSQL 日志
kubectl --context k3d-devops -n paas logs -l app.kubernetes.io/name=postgresql

# 3. 测试连接
kubectl --context k3d-devops exec -n paas deployment/postgresql -- \
  psql -h localhost -U kindler -d kindler -c "SELECT 1"

# 4. 检查 Service
kubectl --context k3d-devops -n paas get svc postgresql
```

### 业务集群问题

#### 集群创建失败

**症状**: `create_env.sh` 执行失败

**排查步骤**:
```bash
# 1. 检查集群是否已存在
k3d cluster list
kind get clusters

# 2. 检查 Docker 资源
docker ps
docker stats

# 3. 查看详细日志（启用 DRY_RUN）
DRY_RUN=1 ./scripts/create_env.sh -n test -p k3d

# 4. 手动创建测试
k3d cluster create test --config clusters/k3d-default.yaml
```

#### Portainer Edge Agent 不健康

**症状**: Portainer 中集群状态显示 "Unhealthy"

**排查步骤**:
```bash
# 1. 检查 Edge Agent Pod 状态
kubectl --context k3d-<cluster_name> -n portainer-edge get pods

# 2. 检查 Edge Agent 日志
kubectl --context k3d-<cluster_name> -n portainer-edge logs -l app=portainer-edge-agent

# 3. 检查镜像是否拉取成功
kubectl --context k3d-<cluster_name> -n portainer-edge describe pod -l app=portainer-edge-agent

# 4. 手动预加载镜像
docker pull portainer/agent:latest
k3d image import portainer/agent:latest -c <cluster_name>

# 5. 重新部署 Edge Agent
kubectl --context k3d-<cluster_name> -n portainer-edge rollout restart deployment portainer-edge-agent
```

#### ArgoCD Applications 状态 Unknown

**症状**: ArgoCD 中 Application 状态显示 "Unknown"

**排查步骤**:
```bash
# 1. 检查 ArgoCD 集群连接
kubectl --context k3d-devops -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster

# 2. 查看集群 secret 详情
kubectl --context k3d-devops -n argocd get secret cluster-<cluster_name> -o yaml

# 3. 检查 API server 地址
kubectl --context k3d-devops -n argocd get secret cluster-<cluster_name> -o jsonpath='{.data.server}' | base64 -d

# 4. 测试 API server 连接
kubectl --context k3d-<cluster_name> get nodes

# 5. 重新注册集群
./scripts/argocd_register.sh unregister <cluster_name> <provider>
./scripts/argocd_register.sh register <cluster_name> <provider>
```

#### whoami 应用无法访问

**症状**: `curl https://whoami.kind.dev.192.168.51.30.sslip.io` 失败

**排查步骤**:
```bash
# 1. 检查 ArgoCD Application 状态
kubectl --context k3d-devops -n argocd get applications

# 2. 检查 whoami Pod 状态
kubectl --context kind-dev get pods -n default -l app=whoami

# 3. 检查 Ingress
kubectl --context kind-dev get ingress -n default

# 4. 检查 HAProxy 路由
curl -I http://192.168.51.30 -H 'Host: whoami.kind.dev.192.168.51.30.sslip.io'

# 5. 手动同步 ArgoCD Application
kubectl --context k3d-devops -n argocd patch application whoami-dev -p '{"operation":{"sync":{"revision":"HEAD"}}}' --type merge
```

### 网络问题

#### HAProxy 无法连接到集群

**症状**: HAProxy 日志显示 "connection refused" 或 "no route to host"

**排查步骤**:
```bash
# 1. 检查 HAProxy 网络连接
docker network inspect k3d-shared

# 2. 确认 HAProxy 连接到 k3d-shared 网络
docker inspect haproxy-gw | grep -A10 Networks

# 3. 手动连接 HAProxy 到网络
docker network connect k3d-shared haproxy-gw

# 4. 检查集群容器 IP
docker inspect k3d-<cluster_name>-server-0 | grep IPAddress

# 5. 从 HAProxy 容器测试连接
docker exec haproxy-gw ping -c 3 <cluster_ip>
```

### 日志收集

```bash
# 收集所有相关日志
./scripts/collect_logs.sh > /tmp/kindler-logs.txt

# 手动收集
echo "=== Docker Containers ===" > /tmp/debug.log
docker ps -a >> /tmp/debug.log
echo "=== k3d Clusters ===" >> /tmp/debug.log
k3d cluster list >> /tmp/debug.log
echo "=== kind Clusters ===" >> /tmp/debug.log
kind get clusters >> /tmp/debug.log
echo "=== Portainer Logs ===" >> /tmp/debug.log
docker logs portainer-ce --tail 100 >> /tmp/debug.log
echo "=== HAProxy Logs ===" >> /tmp/debug.log
docker logs haproxy-gw --tail 100 >> /tmp/debug.log
echo "=== ArgoCD Pods ===" >> /tmp/debug.log
kubectl --context k3d-devops -n argocd get pods >> /tmp/debug.log
```

## 最佳实践

### 开发环境

1. **保持 devops 集群运行**: 避免频繁重建，节省时间
2. **使用 k3d**: 启动速度快，资源占用少
3. **定期清理业务集群**: `./scripts/clean.sh` 释放资源
4. **使用 DRY_RUN 测试**: `DRY_RUN=1 ./scripts/create_env.sh -n test -p k3d`

### 生产环境

1. **备份配置**: 定期备份 `config/` 目录和 PostgreSQL 数据
2. **监控资源**: 使用 `docker stats` 和 `kubectl top` 监控资源使用
3. **日志轮转**: 配置 Docker 日志轮转，避免磁盘占满
4. **版本固定**: 在 `config/clusters.env` 固定镜像版本

### 故障恢复

1. **快速恢复**: 使用 `bootstrap.sh` 快速重建 devops 集群
2. **数据恢复**: 从 PostgreSQL 备份恢复集群配置
3. **渐进式恢复**: 先恢复 devops 集群，再逐个恢复业务集群
4. **验证完整性**: 使用 `scripts/smoke.sh` 验证所有服务

## 相关文档

- [AGENTS.md](../AGENTS.md) - 项目规范和约束
- [ARCHITECTURE.md](ARCHITECTURE.md) - 架构设计
- [REGRESSION_TEST.md](REGRESSION_TEST.md) - 回归测试流程
- [README_CN.md](../README_CN.md) - 项目介绍

