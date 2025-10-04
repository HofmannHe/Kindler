# 技术债务清单

本文档记录系统当前存在的技术债务，按优先级排序。每项债务包含问题描述、影响评估、解决方案和工作量估算。

**最后更新**: 2025-10-01
**维护者**: Architecture Reviewer

---

## 🟡 HIGH Priority（建议近期解决）

### 1. Portainer Edge Agent DNS 解析失败

**发现日期**: 2025-10-01
**影响**: MEDIUM - Pod CrashLoopBackOff 但不影响功能
**所属组件**: Portainer Edge Agent

#### 问题描述
Edge Agent pods 持续 CrashLoopBackOff，日志显示：
```
lookup s-portainer-agent-headless on 10.43.0.10:53: no such host
```

实际 Service 名称为 `portainer-agent-headless`（缺少 "s-" 前缀）

#### 根因分析
1. Deployment 中环境变量 `AGENT_CLUSTER_ADDR` 配置为 `portainer-edge-agent-headless`
2. Portainer Agent 容器内部尝试解析 `s-portainer-agent-headless`（自动添加前缀）
3. Service 命名不一致导致 DNS 查找失败

#### 当前影响
- ✅ **功能正常**: Portainer API 显示所有 K3D 集群 Status=1（已连接）
- ⚠️ **日志污染**: Pod 日志充满错误信息
- ⚠️ **资源浪费**: 持续重启消耗 CPU/内存
- ⚠️ **监控干扰**: CrashLoopBackOff 会触发告警

#### 解决方案

**方案 A（推荐）**: 修改 Service 名称
```yaml
apiVersion: v1
kind: Service
metadata:
  name: s-portainer-agent-headless  # 添加 "s-" 前缀
  namespace: portainer
spec:
  clusterIP: None
  selector:
    app: portainer-edge-agent
  ports:
  - port: 80
    targetPort: 80
```

**方案 B**: 升级 Portainer Agent 镜像
```yaml
containers:
- name: agent
  image: portainer/agent:2.33.3  # 尝试最新稳定版
```

#### 实施步骤
1. 备份当前 Deployment 和 Service 配置
2. 修改 `manifests/portainer/edge-agent.yaml`
3. 对所有 K3D 集群执行 `kubectl apply`
4. 验证 Pod 状态变为 Running
5. 确认 Portainer API 连接状态仍为 Status=1

#### 工作量估算
- **开发时间**: 2 小时
- **测试时间**: 1 小时
- **总计**: 0.5 天

#### 验收标准
- [ ] Edge Agent pods 状态为 Running (1/1)
- [ ] Pod 日志无 DNS 错误
- [ ] Portainer API 显示所有集群 Status=1
- [ ] 持续运行 1 小时无重启

---

### 2. HAProxy 历史路由清理

**发现日期**: 2025-10-01
**影响**: LOW - 配置混乱但不影响功能
**所属组件**: HAProxy

#### 问题描述
`compose/haproxy/haproxy.cfg` 中存在 10+ 条指向不存在集群的路由：
```haproxy
acl host_test-k3d-fixed  hdr(host) -i test-k3d-fixed.local
backend be_test-k3d-fixed
  server s1 127.0.0.1:30080

acl host_invalid-env  hdr(host) -i invalid-env.local
backend be_invalid-env
  server s1 10.10.8.2:30080

acl host_debug-k3d  hdr(host) -i debug-k3d.local
backend be_debug-k3d
  server s1 127.0.0.1:30080
```

#### 当前影响
- ⚠️ **配置混乱**: 难以区分有效路由和历史遗留
- ⚠️ **维护困难**: 新增路由时需要手动排查
- ⚠️ **资源浪费**: HAProxy 加载无用配置

#### 解决方案

**执行清理脚本**:
```bash
cd /home/cloud/github/hofmannhe/mydockers/k3d
./scripts/haproxy_sync.sh --prune
```

该脚本应该：
1. 读取 `config/environments.csv` 获取有效环境列表
2. 扫描 HAProxy 配置中的所有 ACL 和 backend
3. 删除不在有效列表中的路由配置
4. 重新加载 HAProxy 配置

#### 实施步骤
1. 备份当前 HAProxy 配置：`cp compose/haproxy/haproxy.cfg compose/haproxy/haproxy.cfg.bak`
2. 执行 `./scripts/haproxy_sync.sh --prune`
3. 验证配置语法：`docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg`
4. 重启 HAProxy：`docker compose -f compose/haproxy/docker-compose.yml restart`
5. 测试所有有效路由：`curl -H "Host: dev-k3d-argocd.local" http://localhost:23080`

#### 工作量估算
- **开发时间**: 1 小时（如果脚本不存在需要实现）
- **测试时间**: 1 小时
- **总计**: 0.5 天

#### 验收标准
- [ ] HAProxy 配置仅包含有效环境的路由
- [ ] 配置语法检查通过
- [ ] 所有有效路由返回 HTTP 200
- [ ] 无用路由返回 HTTP 404

---

## 🟢 MEDIUM Priority（后续迭代优化）

### 3. HAProxy Backend 健康检查缺失

**发现日期**: 2025-10-01
**影响**: MEDIUM - 无法自动剔除故障节点
**所属组件**: HAProxy

#### 问题描述
当前所有 backend 配置未启用健康检查：
```haproxy
backend be_dev-k3d-argocd
  server s1 10.10.6.2:30800
```

如果后端服务故障，HAProxy 会持续转发请求到故障节点，导致：
- 请求超时（30s）
- 用户体验下降
- 故障节点无法自动摘除

#### 解决方案

**启用 HTTP 健康检查**:
```haproxy
backend be_dev-k3d-argocd
  option httpchk GET /
  http-check expect status 200
  server s1 10.10.6.2:30800 check inter 10s fall 3 rise 2
```

**参数说明**:
- `inter 10s`: 每 10 秒检查一次
- `fall 3`: 连续 3 次失败后标记为 DOWN
- `rise 2`: 连续 2 次成功后标记为 UP

#### 实施步骤
1. 修改 `compose/haproxy/haproxy.cfg` 中所有 backend
2. 验证 ArgoCD 服务支持 `/` 路径健康检查
3. 重新加载 HAProxy 配置
4. 通过 HAProxy stats 页面验证健康状态

#### 工作量估算
- **开发时间**: 2 小时
- **测试时间**: 2 小时
- **总计**: 1 天

#### 验收标准
- [ ] 所有 backend 配置健康检查
- [ ] 健康节点显示 UP 状态
- [ ] 手动停止后端服务，HAProxy 自动摘除
- [ ] 恢复后端服务，HAProxy 自动加回

---

### 4. 脚本幂等性改进

**发现日期**: 2025-10-01
**影响**: LOW - 多次执行可能导致重复配置
**所属组件**: 运维脚本

#### 问题描述
`/tmp/fix_edge_agent.sh` 缺少幂等性检查，多次执行会重复添加 `KUBERNETES_POD_IP` 环境变量：
```bash
kubectl patch deployment portainer-edge-agent -n portainer --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {"name": "KUBERNETES_POD_IP", ...}
  }
]'
```

#### 解决方案

**添加前置检查**:
```bash
# 检查环境变量是否已存在
if kubectl get deployment portainer-edge-agent -n portainer \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBERNETES_POD_IP")]}' \
     | grep -q KUBERNETES_POD_IP; then
  echo "✅ KUBERNETES_POD_IP 已存在，跳过"
  exit 0
fi

# 添加环境变量
kubectl patch ...
```

#### 实施步骤
1. 审计所有运维脚本（`scripts/*.sh`）
2. 为每个操作添加前置检查
3. 使用 `kubectl wait` 替代 `sleep` 等待
4. 添加单元测试验证幂等性

#### 工作量估算
- **开发时间**: 3 小时
- **测试时间**: 1 小时
- **总计**: 0.5 天

#### 验收标准
- [ ] 所有脚本支持多次执行不报错
- [ ] 第二次执行时跳过已完成的步骤
- [ ] 添加 `bats` 测试验证幂等性

---

### 5. 密码管理改进

**发现日期**: 2025-10-01
**影响**: MEDIUM - 安全风险
**所属组件**: Portainer

#### 问题描述
Portainer 管理员密码存储在明文配置文件：
```bash
# config/secrets.env
PORTAINER_ADMIN_PASSWORD=AdminAdmin87654321
```

问题：
- ⚠️ 密码强度较弱（虽然符合要求但不够随机）
- ⚠️ 明文存储在 Git 仓库（即使在 `.gitignore` 中）
- ⚠️ 容器启动时通过环境变量注入（可能泄露）

#### 解决方案

**方案 A**: 使用 Docker Secrets
```yaml
# compose/portainer/docker-compose.yml
services:
  portainer:
    secrets:
      - portainer_admin_password
    command: >
      --admin-password-file /run/secrets/portainer_admin_password

secrets:
  portainer_admin_password:
    file: ./secrets/admin_password.txt
```

**方案 B**: 使用环境变量注入（从外部密钥管理系统）
```bash
export PORTAINER_ADMIN_PASSWORD=$(vault kv get -field=password secret/portainer)
docker compose up -d
```

#### 实施步骤
1. 生成强随机密码：`openssl rand -base64 32`
2. 创建 Docker Secret 或存储到密钥管理系统
3. 修改 `compose/portainer/docker-compose.yml`
4. 更新文档说明新的密码管理流程

#### 工作量估算
- **开发时间**: 2 小时
- **测试时间**: 1 小时
- **文档时间**: 1 小时
- **总计**: 1 天

#### 验收标准
- [ ] 密码不以明文存储在 Git 仓库
- [ ] Portainer 启动时从 Secret 读取密码
- [ ] 文档更新包含密码轮换流程

---

## 📝 已解决的技术债务

### ✅ KUBERNETES_POD_IP 环境变量缺失

**解决日期**: 2025-10-01
**解决方案**: 通过 `kubectl patch` 添加 downward API 注入

**修复前问题**:
```
KUBERNETES_POD_IP env var must be specified
```

**修复后配置**:
```yaml
env:
- name: KUBERNETES_POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
```

**验证结果**: ✅ Portainer API 显示所有集群 Status=1

---

## 维护指南

### 如何添加新的技术债务

1. 复制模板：
```markdown
### N. 债务标题

**发现日期**: YYYY-MM-DD
**影响**: HIGH/MEDIUM/LOW - 简要描述
**所属组件**: 组件名称

#### 问题描述
详细描述问题...

#### 解决方案
建议的解决方案...

#### 工作量估算
- **开发时间**: X 小时
- **测试时间**: Y 小时
- **总计**: Z 天

#### 验收标准
- [ ] 验收标准 1
- [ ] 验收标准 2
```

2. 提交 PR 并关联 issue
3. 在每周技术债务会议上讨论优先级

### 如何标记债务已解决

1. 将债务条目移动到"已解决的技术债务"章节
2. 添加解决日期和方案
3. 更新相关文档（如有）

---

**下次审查**: 2025-10-15 或有新债务发现时
