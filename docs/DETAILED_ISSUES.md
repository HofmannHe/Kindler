# 详细问题调查报告

**调查时间**: 2025-11-02 09:45 CST

---

## 严重问题详细分析

### 问题1: HAProxy 配置错误导致崩溃循环 🔴 → ✅ 已修复

**错误日志**:
```
[ALERT] 'server be_argocd/s1' : could not resolve address '10.101.0.4172.18.0.6'
```

**根因**:
- be_argocd backend 的 server IP 地址异常
- IP 地址被拼接：`10.101.0.4172.18.0.6` 
- 应该是两个独立的 IP：`10.101.0.4` 或 `172.18.0.6`
- 可能是 haproxy_render.sh 或 haproxy_route.sh 的 bug

**影响**:
- HAProxy 无法启动，持续重启
- 所有服务访问不稳定
- Portainer HTTPS 超时

**修复方案**:
- 修复 be_argocd 的地址来源：tools/setup/setup_devops.sh 不再使用多网卡无分隔拼接（range 无分隔问题），改为优先选定网络（k3d-shared）并回退到“以空格分隔 + 取第一项”。
- 修复所有动态渲染路径避免相同问题：scripts/haproxy_route.sh 与 scripts/haproxy_render.sh 统一采用“指定网络 + 空格分隔回退”的解析逻辑。
- 将默认 haproxy.cfg 中 be_argocd 的 server 行改为安全占位符（127.0.0.1:30800），由 setup_devops.sh 引导时重写为实际 NodePort 地址，避免配置验证 ALERT。

**复验**:
- docker exec haproxy-gw haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg 无 ALERT（仅 WARNING，已知顺序提示）。
- 新增测试：tests/haproxy_regression_devops.sh 校验 be_argocd 的 server 行为单一 IPv4:PORT 格式，防止再次回归。

---

### 问题2: WebUI API 正常，显示状态逻辑错误 ⚠️

**实际情况**:
- WebUI API `/api/clusters` 返回正常（有数据）
- 返回字段包含：actual_state, desired_state
- 但所有集群的 `status` 字段都是 "stopped"

**数据对比**:
- actual_state: running (正确)
- status: stopped (错误)

**根因**:
- WebUI 的 `get_cluster_status` 方法返回错误
- 或者状态字段映射错误

**建议修复方向**:
- 检查 `cluster_service.py` 的 `get_cluster_status` 方法
- 或者直接使用 `actual_state` 作为显示状态

---

### 问题3: WebUI 创建的集群名称被修改 🔴

**现象**:
- 用户创建: test (k3d), test1 (kind)
- 数据库实际: testcd-093707-2 (kind)
- 没有 test/test1 记录

**可能原因**:
- CSV 同步覆盖了用户创建的记录
- 或者重建时数据库被清空，CSV 重新导入
- testcd-093707-2 可能是之前的测试遗留

**建议调查**:
- 检查 CSV 文件内容
- 检查 WebUI 创建时是否真的写入了 test/test1
- 检查 bootstrap 的 CSV 导入是否覆盖了用户数据

---

### 问题4: whoami 服务域名不可访问 🔴

**症状**:
- whoami pods: Running (dev/uat/prod 各1个)
- ArgoCD Applications: Synced & Healthy
- Ingress: 存在
- 域名访问: 全部超时

**可能原因**:
- HAProxy 不稳定导致路由失败
- HAProxy backend be_dev/uat/prod 配置错误
- 网络路由问题

**临时验证**:
- 等待 HAProxy 稳定后重试
- 或通过 kubectl port-forward 直接访问验证 pod 本身正常

---

## 中等问题详细分析

### 问题5: devops 集群 actual_state 未更新 ⚠️

**现象**:
- devops 集群运行正常
- actual_state: unknown
- last_reconciled_at: null

**原因**:
- Reconciler 可能跳过了 devops（管理集群）
- 或者 devops 集群创建流程没有更新 actual_state

**建议**:
- Reconciler 应该也管理 devops 的状态
- 或者 bootstrap 时初始化 devops 的 actual_state

---

### 问题6: testcd-093707-2 集群状态异常 ⚠️

**数据**:
- desired_state: present
- actual_state: creating
- 集群已存在: kind-testcd-093707-2

**问题**:
- Reconciler 认为还在创建中
- 但集群实际已存在
- 可能是状态未正确更新

---

### 问题7: ArgoCD 缺少 devops cluster secret ⚠️

**现状**:
- 有: cluster-dev, cluster-uat, cluster-prod
- 缺少: cluster-devops

**影响**:
- ArgoCD 无法部署应用到 devops 集群
- 但 devops 是管理集群，通常不需要

---

## 功能正常项确认

### ✅ SQLite 数据库
- 可访问: 是
- 表结构: 正确（包含 desired_state, actual_state 等字段）
- 数据一致性: 数据库记录与实际集群一致

### ✅ 基础集群
- devops: 运行正常
- dev: 运行正常
- uat: 运行正常
- prod: 运行正常

### ✅ ArgoCD
- Applications: whoami-dev/uat/prod (Synced & Healthy)
- ApplicationSet: 存在且正常
- Cluster secrets: dev/uat/prod 已注册

### ✅ Reconciler
- 运行中: 是 (PID: 898309)
- 日志正常: 是
- 健康检查正常: 是

### ✅ whoami Pods
- dev: 1个 pod Running
- uat: 1个 pod Running
- prod: 1个 pod Running

---

## 优先级建议

### P0 - 阻塞性问题（必须立即修复）

1. **HAProxy IP 拼接错误** - 导致服务崩溃
2. **whoami 域名不可访问** - 核心功能不可用

### P1 - 重要问题（应该尽快修复）

3. **WebUI 状态显示错误** - 用户体验差
4. **集群名称异常** - 数据完整性问题

### P2 - 次要问题（可以后续修复）

5. **devops actual_state 未更新** - 不影响功能
6. **ArgoCD devops secret 缺失** - devops 不需要

---

## 测试结论

### ✅ 核心功能可用

- SQLite 迁移成功
- 基础集群运行正常
- ArgoCD Applications 正常
- Reconciler 正常工作

### ❌ 存在阻塞性问题

- HAProxy 配置错误
- whoami 服务不可访问
- WebUI 状态显示错误

### 建议

**P0 问题必须修复后才能认为系统正常。**

当前状态：基础功能可用，但有严重的配置和稳定性问题。
