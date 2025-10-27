# WebUI 问题诊断报告

## 执行时间
2025-10-23 16:22

## 用户报告的问题

1. **刷新页面后，删除、添加集群的操作状态就看不见了**
2. **添加的集群在portainer中能看到，webui中看不到**
3. **portainer中能看到老的集群，但是状态不正常**
4. **argocd中只能看到预置的集群，即使删除预置集群也是这样，而且看不到通过webui新增的集群**

## 测试用例执行结果

### 测试脚本
`tests/webui_comprehensive_test.sh`

### 测试结果统计
- **Total tests**: 9
- **Passed**: 3
- **Failed**: 6

### 失败的测试
1. ✗ Failed to create task
2. ✗ Test cluster NOT visible in WebUI API
3. ✗ k3d cluster does NOT exist
4. ✗ Test cluster endpoint NOT found in Portainer
5. ✗ ArgoCD cluster secret NOT found
6. ✗ Failed to create delete task

## 根因分析

### 🔴 根本原因：WebUI Backend 无法连接到 PostgreSQL 数据库

**错误日志**：
```
2025-10-23 16:21:45,931 - app.services.db_service - ERROR - Failed to check cluster existence test-webui-full: [Errno 111] Connection refused
2025-10-23 16:21:45,932 - app.services.db_service - ERROR - Failed to create cluster: [Errno 111] Connection refused
```

**配置检查**：
- WebUI Backend 环境变量：`PG_HOST=haproxy-gw`, `PG_PORT=5432`
- PostgreSQL Service：`type: ClusterIP`, `clusterIP: None` (Headless)
- HAProxy 配置：指向 `172.18.0.6:30432`（NodePort不存在）

**问题**：
1. PostgreSQL Service 是 ClusterIP 类型，无 NodePort
2. HAProxy 配置引用的 NodePort (30432) 不存在
3. WebUI Backend 通过 HAProxy 无法访问 PostgreSQL

**影响范围**：
- ✗ 无法创建集群（数据库插入失败）
- ✗ 无法列出集群（数据库查询失败）
- ✗ 无法删除集群（数据库查询失败）
- ✗ 所有需要数据库的WebUI操作全部失败

### 🟡 次要问题：ArgoCD 孤立 Secret

**发现**：
```bash
$ kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster -o name
secret/cluster-test
secret/cluster-test1
```

**原因**：
- 之前通过WebUI创建的 `test` 和 `test1` 集群
- 删除时未清理 ArgoCD cluster secret
- 可能是 `delete_env.sh` 的清理逻辑不完整

### 🟡 测试用例问题：Portainer API 响应格式

**错误**：
```
jq: error (at <stdin>:1): Cannot index string with string "Name"
```

**原因**：
- Portainer API 可能返回非预期的JSON格式
- 测试脚本的jq解析逻辑需要更健壮

## 修复计划

### 优先级 P0：修复PostgreSQL连接

**方案A：修改PostgreSQL Service为NodePort（推荐）**

1. 修改外部Git仓库中的 `postgresql/templates/service.yaml`
2. 添加 `type: NodePort` 和 `nodePort: 30432`
3. ArgoCD 自动同步部署
4. 验证 HAProxy 能连接到 PostgreSQL

**优点**：
- 配置固定，不会因Pod重启而变化
- HAProxy 配置无需频繁更新
- 符合现有架构设计（其他服务也用NodePort）

**缺点**：
- 需要修改Git仓库（GitOps流程）
- 需要等待ArgoCD同步

**方案B：更新HAProxy配置使用Pod IP**

1. 获取PostgreSQL Pod IP
2. 更新HAProxy配置文件
3. 重载HAProxy

**优点**：
- 快速修复，无需等待Git同步

**缺点**：
- Pod IP可能变化
- 需要定期更新或监控

**决策：选择方案A**，因为：
- 更符合GitOps原则
- 配置更稳定
- 长期维护成本低

### 优先级 P1：清理孤立资源

1. 清理ArgoCD孤立secret：
   ```bash
   kubectl -n argocd delete secret cluster-test cluster-test1
   ```

2. 验证 `delete_env.sh` 的ArgoCD清理逻辑
3. 如需要，修复清理脚本

### 优先级 P2：增强测试用例

1. 修复Portainer API响应解析
2. 添加更详细的错误信息
3. 添加数据库连接前置检查

## 验证计划

### 步骤1：修复PostgreSQL连接
1. 修改Git仓库中的postgresql manifests
2. 等待ArgoCD同步
3. 验证：`nc -zv 192.168.51.30 30432`
4. 验证：WebUI backend日志无连接错误

### 步骤2：验证WebUI功能
1. GET /api/clusters 能返回devops集群
2. POST /api/clusters 能创建新集群
3. DELETE /api/clusters/{name} 能删除集群
4. 所有操作的task能正常追踪

### 步骤3：运行完整回归测试
```bash
./tests/webui_comprehensive_test.sh
```

**通过标准**：
- ✅ Total tests: 9
- ✅ Passed: 9
- ✅ Failed: 0

## 举一反三

### 测试用例改进

**当前问题**：
- 测试未检查数据库连接状态
- 测试未验证前置条件（如PostgreSQL可达性）

**改进**：
1. 添加 `check_db_connectivity()` 前置检查
2. 在失败时输出详细的诊断信息
3. 区分不同类型的失败（网络、配置、业务逻辑）

### 架构改进

**当前问题**：
- WebUI依赖外部服务（PostgreSQL）但无健康检查
- 服务启动顺序无保证

**改进**：
1. WebUI backend 添加数据库连接重试机制
2. 添加 `/api/health/db` 端点检查数据库连接
3. 在docker-compose中添加depends_on和健康检查

### 文档改进

**需要补充**：
1. WebUI部署依赖清单（PostgreSQL NodePort）
2. 故障排查指南（连接失败时如何诊断）
3. 端口映射表（所有NodePort和用途）

## 附录：相关配置

### PostgreSQL当前配置
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: paas
spec:
  type: ClusterIP         # ← 问题：应该是NodePort
  clusterIP: None
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
  selector:
    app: postgresql
```

### HAProxy当前配置
```
backend postgres
  mode tcp
  balance leastconn
  option tcp-check
  server postgres1 172.18.0.6:30432 check inter 5s fall 3 rise 2
  # ← 问题：30432端口不存在
```

### WebUI Backend环境变量
```
PG_HOST=haproxy-gw
PG_PORT=5432
PG_DATABASE=kindler
PG_USER=kindler
PG_PASSWORD=postgres123
```

