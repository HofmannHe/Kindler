# Kindler Reconciler - 声明式集群管理

## 简介

Reconciler 是 Kindler 的后台服务，实现声明式集群管理。

### 工作原理

```
用户/WebUI → 声明期望状态（写入数据库）
                    ↓
            Reconciler（后台服务）
                    ↓
            读取数据库 → 调和实际状态 → 执行操作
```

## 快速开始

### 启动 Reconciler

```bash
cd /home/cloud/github/hofmannhe/kindler
./scripts/start_reconciler.sh start
```

### 查看状态

```bash
./scripts/start_reconciler.sh status
```

### 查看日志

```bash
./scripts/start_reconciler.sh logs
```

### 停止 Reconciler

```bash
./scripts/start_reconciler.sh stop
```

## 使用方式

### 1. 通过 WebUI 创建集群

1. 访问 WebUI: `http://kindler.devops.<BASE_DOMAIN>`
2. 填写集群信息并提交
3. WebUI 写入数据库（desired_state='present'）
4. Reconciler 在 30秒内自动创建集群
5. 刷新 WebUI 查看状态变化

### 2. 通过脚本创建集群（仍然支持）

```bash
./scripts/create_env.sh -n my-cluster -p k3d
```

两种方式最终都调用相同的 create_env.sh，保证一致性。

## 状态说明

### desired_state（期望状态）

- `present` - 期望集群存在
- `absent` - 期望集群不存在

### actual_state（实际状态）

- `unknown` - 未知（新创建的记录）
- `creating` - 正在创建中
- `running` - 运行正常
- `failed` - 创建/运行失败
- `deleting` - 正在删除中

### 状态转换

**创建流程**：
```
unknown → creating → running
        ↓ (如果失败)
      failed
```

**删除流程**：
```
running → deleting → (从数据库删除)
        ↓ (如果失败)
      failed
```

## Reconciler 逻辑

### 调和规则

1. **desired=present, actual=unknown/failed** → 创建集群
2. **desired=present, actual=creating** → 验证是否完成
3. **desired=present, actual=running** → 健康检查
4. **desired=absent, actual=running/failed** → 删除集群
5. **desired=absent, actual=deleting** → 验证是否完成

### 重试机制

- 失败的操作会在下一个周期自动重试
- Reconcile 间隔：30秒
- 健康检查间隔：5分钟

## 日志和排查

### 日志位置

```
/tmp/kindler_reconciler.log
```

### 查看实时日志

```bash
./scripts/start_reconciler.sh logs
```

### 手动触发 Reconcile

```bash
./scripts/reconciler.sh once
```

## 部署选项

### 选项 1: 后台进程（当前）

```bash
./scripts/start_reconciler.sh start
```

### 选项 2: cron 任务

```bash
# 编辑 crontab
crontab -e

# 添加
*/1 * * * * cd /home/cloud/github/hofmannhe/kindler && ./scripts/reconciler.sh once
```

### 选项 3: systemd 服务（生产推荐）

创建 `/etc/systemd/system/kindler-reconciler.service`:
```ini
[Unit]
Description=Kindler Cluster Reconciler
After=docker.service

[Service]
Type=simple
User=cloud
WorkingDirectory=/home/cloud/github/hofmannhe/kindler
ExecStart=/home/cloud/github/hofmannhe/kindler/scripts/reconciler.sh loop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

然后：
```bash
sudo systemctl daemon-reload
sudo systemctl enable kindler-reconciler
sudo systemctl start kindler-reconciler
```

## 故障排查

### 集群一直是 creating 状态

1. 查看日志：`./scripts/start_reconciler.sh logs`
2. 查看错误：数据库中的 `reconcile_error` 字段
3. 手动运行：`./scripts/reconciler.sh once`

### 集群创建失败

1. 查看详细日志：`/tmp/reconcile_create_<cluster-name>.log`
2. 检查 reconcile_error 字段
3. Reconciler 会自动重试

### Reconciler 未运行

```bash
./scripts/start_reconciler.sh status
./scripts/start_reconciler.sh start
```

## 总结

Reconciler 实现了声明式集群管理，让 WebUI 创建集群与脚本创建（预置集群）完全一致，稳定可靠。

