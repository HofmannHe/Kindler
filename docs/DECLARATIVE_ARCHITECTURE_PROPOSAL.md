# 声明式架构方案 - WebUI 创建集群

## 核心思想

### 当前架构（命令式）❌

```
WebUI → 执行 create_env.sh → 创建集群 → 写入数据库
```

**问题**：
- WebUI 在容器内执行脚本，工具链不完整
- 执行环境与主机不一致
- 难以实现稳定性

### 建议架构（声明式）✅

```
WebUI → 写入数据库（声明期望状态）
                ↓
        后台服务（Reconciler）→ 读取数据库 → 执行 create_env.sh → 更新状态
```

**优点**：
- WebUI 只负责数据（简单、可靠）
- 后台服务在主机运行（完整工具链）
- 声明式、幂等性、自愈能力
- 符合 Kubernetes Operator 模式

---

## 详细设计

### 1. 数据库 Schema 扩展

```sql
-- clusters 表添加期望状态和实际状态
CREATE TABLE clusters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  provider TEXT NOT NULL,
  
  -- 期望状态（用户声明）
  desired_state TEXT DEFAULT 'present',  -- present, absent
  
  -- 实际状态（reconciler 维护）
  actual_state TEXT DEFAULT 'unknown',   -- unknown, creating, running, failed, deleting, deleted
  
  -- 其他字段...
  node_port INTEGER,
  pf_port INTEGER,
  http_port INTEGER,
  https_port INTEGER,
  server_ip TEXT,
  
  -- 状态同步
  last_reconciled_at TIMESTAMP,
  reconcile_error TEXT,
  
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### 2. WebUI 行为

```python
# WebUI API - 只负责写入数据库

@router.post("/clusters")
async def create_cluster(cluster: ClusterCreate):
    """声明期望创建集群（不直接执行）"""
    
    # 1. 检查集群是否已存在
    if await db_service.cluster_exists(cluster.name):
        raise HTTPException(409, "Cluster already exists")
    
    # 2. 写入数据库（声明期望状态）
    await db_service.insert_cluster({
        "name": cluster.name,
        "provider": cluster.provider,
        "desired_state": "present",      # 声明：我想要这个集群存在
        "actual_state": "unknown",        # 实际：还不知道状态
        "node_port": cluster.node_port,
        "pf_port": cluster.pf_port,
        ...
    })
    
    # 3. 立即返回（不等待创建完成）
    return {
        "message": "Cluster creation requested",
        "name": cluster.name,
        "status": "pending"  # reconciler 会处理
    }

@router.delete("/clusters/{name}")
async def delete_cluster(name: str):
    """声明期望删除集群（不直接执行）"""
    
    # 只修改期望状态
    await db_service.update_cluster(name, {
        "desired_state": "absent",  # 声明：我不想要这个集群了
    })
    
    return {"message": "Cluster deletion requested"}
```

### 3. 后台 Reconciler 服务

```python
# scripts/reconciler.py 或单独的 reconciler 服务

import time
import subprocess
from db import get_db

def reconcile_loop():
    """持续运行的 reconcile 循环"""
    
    db = get_db()
    
    while True:
        try:
            # 1. 读取所有需要 reconcile 的集群
            clusters = db.query("""
                SELECT * FROM clusters 
                WHERE desired_state != actual_state 
                   OR actual_state IN ('creating', 'deleting')
                   OR (last_reconciled_at IS NULL OR 
                       datetime('now', '-5 minutes') > last_reconciled_at)
            """)
            
            for cluster in clusters:
                reconcile_cluster(cluster)
            
            # 2. 等待下一个周期（例如 30 秒）
            time.sleep(30)
            
        except Exception as e:
            logger.error(f"Reconcile error: {e}")
            time.sleep(60)

def reconcile_cluster(cluster):
    """调和单个集群的期望状态和实际状态"""
    
    name = cluster['name']
    desired = cluster['desired_state']
    actual = cluster['actual_state']
    
    # Case 1: 期望存在，实际不存在或未知 → 创建
    if desired == 'present' and actual in ('unknown', 'failed'):
        create_cluster_impl(cluster)
    
    # Case 2: 期望不存在，实际存在 → 删除
    elif desired == 'absent' and actual in ('running', 'failed'):
        delete_cluster_impl(cluster)
    
    # Case 3: 期望存在，实际存在 → 验证健康状态
    elif desired == 'present' and actual == 'running':
        verify_cluster_health(cluster)
    
    # Case 4: 期望不存在，实际不存在 → 清理数据库记录
    elif desired == 'absent' and actual == 'deleted':
        db.delete_cluster(name)

def create_cluster_impl(cluster):
    """实际创建集群（在主机上执行 create_env.sh）"""
    
    # 1. 更新状态为 creating
    db.update_cluster(cluster['name'], {
        'actual_state': 'creating',
        'last_reconciled_at': datetime.now()
    })
    
    # 2. 执行创建脚本（在主机上，与预置集群完全相同）
    result = subprocess.run([
        '/home/cloud/github/hofmannhe/kindler/scripts/create_env.sh',
        '-n', cluster['name'],
        '-p', cluster['provider'],
        '--node-port', str(cluster['node_port']),
        '--pf-port', str(cluster['pf_port'])
    ], capture_output=True, text=True)
    
    # 3. 更新状态
    if result.returncode == 0:
        db.update_cluster(cluster['name'], {
            'actual_state': 'running',
            'last_reconciled_at': datetime.now(),
            'reconcile_error': None
        })
    else:
        db.update_cluster(cluster['name'], {
            'actual_state': 'failed',
            'last_reconciled_at': datetime.now(),
            'reconcile_error': result.stderr
        })
```

### 4. 部署方式

**选项 A：主机上的 systemd 服务**（推荐）

```ini
# /etc/systemd/system/kindler-reconciler.service
[Unit]
Description=Kindler Cluster Reconciler
After=docker.service

[Service]
Type=simple
User=cloud
WorkingDirectory=/home/cloud/github/hofmannhe/kindler
ExecStart=/usr/bin/python3 /home/cloud/github/hofmannhe/kindler/scripts/reconciler.py
Restart=always

[Install]
WantedBy=multi-user.target
```

**选项 B：独立容器（在主机网络中）**

```yaml
# compose/infrastructure/docker-compose.yml
services:
  kindler-reconciler:
    build: ../../reconciler
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ../../:/workspace
      - /usr/local/bin/k3d:/usr/local/bin/k3d:ro
      - /usr/local/bin/kind:/usr/local/bin/kind:ro
      - ${HOME}/.kube:/root/.kube
    environment:
      - DATABASE_PATH=/workspace/data/kindler-webui/kindler.db
    command: python3 /workspace/scripts/reconciler.py
```

**选项 C：cron 任务**（最简单）

```bash
# crontab -e
*/1 * * * * cd /home/cloud/github/hofmannhe/kindler && python3 scripts/reconciler.py
```

---

## 优势分析

### 1. 解耦合

- WebUI 不关心如何创建集群
- Reconciler 不关心请求从哪来
- 各自专注于自己的职责

### 2. 可靠性

- Reconciler 在主机运行，工具链完整
- 执行环境与预置集群完全一致
- 错误可以重试（自动 reconcile）

### 3. 一致性

- 所有创建都通过相同的脚本
- 预置集群和动态集群没有差别
- 数据库是唯一的真实来源

### 4. 可观测性

- 数据库记录完整的状态转换
- WebUI 可以实时显示进度
- 错误信息记录在数据库中

### 5. 幂等性和自愈

- Reconciler 持续运行，自动修复不一致
- 如果创建失败，会自动重试
- 符合 Kubernetes Operator 模式

---

## 实施成本评估

### 最小实现（1-2小时）

1. **扩展数据库 Schema**
   - 添加 desired_state, actual_state 字段
   - 迁移现有数据

2. **修改 WebUI API**
   - 只写入数据库，不执行脚本
   - 返回 pending 状态

3. **创建简单的 Reconciler**
   - Python 脚本，循环读取数据库
   - 调用 create_env.sh 或 delete_env.sh
   - 更新状态

4. **部署为 cron 任务**
   - 每分钟执行一次
   - 足够简单和可靠

### 完整实现（3-5小时）

1. 添加更多状态（creating, running, failed, deleting）
2. 实现错误重试机制
3. 实现健康检查和自愈
4. 实现 systemd 服务或独立容器
5. 添加完整的测试用例

---

## 与现有系统的兼容性

### ✅ 完全兼容

1. **脚本创建方式不变**
   - `create_env.sh` 仍然可以直接使用
   - Reconciler 也调用相同的脚本
   
2. **数据库记录方式不变**
   - `create_env.sh` 仍然写入数据库
   - 只是多了状态字段

3. **预置集群流程不变**
   - `tools/legacy/create_predefined_clusters.sh` 仍然可用
   - 或者改为写入数据库，由 reconciler 创建

---

## 建议的实施步骤

### 阶段 1：最小可用版本（推荐立即实施）

1. **扩展数据库**（10分钟）
   ```sql
   ALTER TABLE clusters ADD COLUMN desired_state TEXT DEFAULT 'present';
   ALTER TABLE clusters ADD COLUMN actual_state TEXT DEFAULT 'unknown';
   ALTER TABLE clusters ADD COLUMN last_reconciled_at TIMESTAMP;
   ALTER TABLE clusters ADD COLUMN reconcile_error TEXT;
   ```

2. **创建 Reconciler 脚本**（30分钟）
   - `scripts/reconciler.sh`（Bash 版本，简单）
   - 读取数据库，调用 create_env.sh/delete_env.sh
   - 更新状态

3. **修改 WebUI API**（20分钟）
   - 只写入数据库，设置 desired_state='present'
   - 返回 pending 状态
   
4. **部署为 cron**（5分钟）
   - 每分钟执行一次 reconciler.sh

**总计**：约 1 小时即可完成基本功能

### 阶段 2：完善功能（后续迭代）

1. 添加更细粒度的状态
2. 实现健康检查
3. 实现错误重试
4. 改为 systemd 服务

---

## 对比评估

### 方案对比

| 方案 | 复杂度 | 可靠性 | 与预置集群一致性 | 实施时间 |
|------|--------|--------|------------------|----------|
| 容器内执行 | 高 | 低 | 低 | 已尝试多次失败 |
| docker run/nsenter | 高 | 中 | 中 | 已尝试，有问题 |
| **声明式架构** | **中** | **高** | **完全一致** | **1-2小时** |
| 禁用 WebUI 创建 | 低 | 高 | N/A | 立即 |

### 推荐方案：声明式架构 ✅

**理由**：
1. **符合设计理念** - 声明式、GitOps、Operator 模式
2. **实施成本可接受** - 1-2 小时可完成基本功能
3. **完全一致性** - Reconciler 调用相同的 create_env.sh
4. **长期可维护** - 清晰的架构，易于扩展

---

## 实施建议

### 立即实施（最小可用版本）

**预计时间**：1-2 小时

**步骤**：
1. 扩展数据库 Schema
2. 创建简单的 Bash reconciler
3. 修改 WebUI API 为声明式
4. 部署为 cron 任务
5. 测试验证

**收益**：
- WebUI 创建功能完全可用
- 与预置集群创建完全一致
- 稳定可靠

### 是否值得？

**YES！** 理由：
1. 解决了根本性架构问题
2. 实施成本低（1-2小时）
3. 长期收益大（稳定性、可维护性）
4. 符合最佳实践（声明式、Operator 模式）

---

## 下一步

如果您同意这个方案，我可以立即实施：

1. 扩展数据库 Schema
2. 创建 `scripts/reconciler.sh`（Bash 版本，简单）
3. 修改 WebUI API 为声明式
4. 测试验证

**预计完成时间**：1-2 小时
**成功率**：高（因为 reconciler 在主机运行，与预置集群完全一致）

您觉得这个方案如何？
