# Web GUI 快速开始指南

## 前置条件

1. 已完成基础环境搭建（devops 集群运行中）
2. Docker 和 Docker Compose 已安装
3. 网络可以访问 192.168.51.30.sslip.io

## 1. 构建和启动服务

### 方法一：集成到基础设施（推荐）

```bash
cd /home/cloud/github/hofmannhe/kindler/worktrees/webui

# 启动所有基础服务（包括 Web GUI）
docker compose -f compose/infrastructure/docker-compose.yml up -d

# 查看服务状态
docker ps | grep kindler-webui
```

### 方法二：独立启动（开发调试）

```bash
cd /home/cloud/github/hofmannhe/kindler/worktrees/webui/webui

# 构建并启动
docker compose up -d --build

# 查看日志
docker compose logs -f
```

## 2. 运行验收测试

```bash
cd /home/cloud/github/hofmannhe/kindler/worktrees/webui/tests

# 运行验收测试（确保服务正常运行）
./acceptance_test.sh
```

预期输出：
```
╔════════════════════════════════════════════════════════════╗
║         Kindler Web GUI 验收测试                           ║
╚════════════════════════════════════════════════════════════╝

===== Test 1: 服务运行状态 =====
[✓] Service kindler-webui-backend is running
[✓] Service kindler-webui-frontend is running
[✓] Service haproxy-gw is running

===== Test 2: 前端访问测试 =====
[INFO] Checking http://kindler.devops.192.168.51.30.sslip.io (expecting 200)
[✓] HTTP 200 OK
[✓] Content contains 'Kindler'

...

╔════════════════════════════════════════════════════════════╗
║                  所有验收测试通过! ✅                      ║
╚════════════════════════════════════════════════════════════╝
```

## 3. 访问 Web GUI

在浏览器中打开：
```
http://kindler.devops.192.168.51.30.sslip.io
```

或使用命令行快速打开：
```bash
xdg-open http://kindler.devops.192.168.51.30.sslip.io  # Linux
open http://kindler.devops.192.168.51.30.sslip.io      # macOS
```

## 4. 运行 API 单元测试

```bash
cd /home/cloud/github/hofmannhe/kindler/worktrees/webui/webui/tests

# 安装测试依赖
pip install -r requirements.txt

# 运行 API 测试
pytest api/ -v

# 查看覆盖率
pytest api/ --cov=app --cov-report=html
```

## 5. 运行 E2E 测试

### 基础 E2E 测试（不创建真实集群）

```bash
cd /home/cloud/github/hofmannhe/kindler/worktrees/webui/webui/tests

# 安装 Playwright
pip install playwright
playwright install chromium

# 运行基础 E2E 测试
pytest e2e/ -v -m "not slow"
```

### 完整 E2E 测试（会创建和删除真实集群）

⚠️ **警告**: 此测试会创建和删除名为 `e2e-test-cluster` 的集群

```bash
# 设置环境变量启用完整测试
export E2E_FULL_TEST=1

# 运行完整 E2E 测试
pytest e2e/test_webui_basic.py::test_create_cluster_workflow -v --headed

# 测试将：
# 1. 打开浏览器
# 2. 创建集群 e2e-test-cluster
# 3. 等待创建完成（2-3分钟）
# 4. 验证集群出现在列表中
# 5. 删除集群
# 6. 等待删除完成（1-2分钟）
```

## 6. 手动功能测试

### 测试 1: 创建集群

1. 访问 Web GUI 主页
2. 点击"创建集群"按钮
3. 填写表单：
   - 名称: `test-webui`
   - Provider: `k3d`
   - 其他使用默认值
4. 点击"创建"
5. 观察任务进度卡片出现
6. 等待任务完成（约 2-3 分钟）
7. 刷新列表，确认集群出现

### 测试 2: 查看集群详情

1. 点击集群名称 `test-webui`
2. 查看详情页面：
   - 配置信息
   - 节点状态
   - Portainer/ArgoCD 状态
3. 点击"访问 Whoami 应用"链接
4. 确认可以访问应用

### 测试 3: 验证自动注册

**Portainer:**
```bash
# 方法 1: 浏览器访问
open http://portainer.devops.192.168.51.30.sslip.io

# 查看 Environments -> Edge Environments
# 应该看到 test-webui 环境且状态为 online
```

**ArgoCD:**
```bash
# 方法 1: 浏览器访问
open http://argocd.devops.192.168.51.30.sslip.io

# 查看 Settings -> Clusters
# 应该看到 k3d-test-webui 集群

# 查看 Applications
# 应该看到 test-webui-whoami 应用且状态 Healthy
```

### 测试 4: 停止和启动集群

1. 在集群列表中找到 `test-webui`
2. 点击"停止"按钮
3. 观察任务进度
4. 等待完成后，状态变为"已停止"
5. 点击"启动"按钮
6. 观察任务进度
7. 等待完成后，状态变为"运行中"

### 测试 5: 删除集群

1. 在集群列表中找到 `test-webui`
2. 点击"删除"按钮
3. 确认删除提示
4. 观察任务进度
5. 等待完成后，集群从列表中消失

### 测试 6: 并发创建多个集群

1. 快速连续创建 3 个集群：
   - `concurrent-1` (k3d)
   - `concurrent-2` (k3d)
   - `concurrent-3` (k3d)
2. 观察 3 个任务进度卡片同时显示
3. 等待所有任务完成
4. 验证所有集群都成功创建
5. 批量删除所有集群

## 7. 验证 DB-Git-K8s 一致性

```bash
# 运行一致性检查
/home/cloud/github/hofmannhe/kindler/scripts/check_consistency.sh

# 预期输出：
# ✓ DB: N clusters
# ✓ Git: N branches
# ✓ K8s: N clusters running
# ✓ All systems consistent
```

## 8. 查看日志

### 后端日志
```bash
docker logs -f kindler-webui-backend

# 应该看到：
# - API 请求日志
# - 脚本执行日志
# - WebSocket 连接日志
```

### 前端日志
```bash
docker logs -f kindler-webui-frontend

# 应该看到：
# - Nginx 访问日志
```

### HAProxy 日志
```bash
docker logs haproxy-gw | grep kindler

# 应该看到 kindler 的路由请求
```

## 9. 性能测试（可选）

### 并发创建测试
```bash
# 同时创建 5 个集群
for i in {1..5}; do
  curl -X POST http://kindler.devops.192.168.51.30.sslip.io/api/clusters \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"perf-test-$i\",
      \"provider\": \"k3d\",
      \"node_port\": 30080,
      \"pf_port\": $((20000+i)),
      \"http_port\": $((20100+i)),
      \"https_port\": $((20200+i)),
      \"cluster_subnet\": \"10.$((200+i)).0.0/16\"
    }" &
done

# 等待所有任务完成
wait

# 查看所有集群
curl -s http://kindler.devops.192.168.51.30.sslip.io/api/clusters | jq '.[] | .name'

# 清理
for i in {1..5}; do
  curl -X DELETE http://kindler.devops.192.168.51.30.sslip.io/api/clusters/perf-test-$i &
done
wait
```

## 10. 故障排查

### 问题 1: 服务启动失败

```bash
# 查看容器状态
docker ps -a | grep kindler-webui

# 查看构建日志
docker compose -f compose/infrastructure/docker-compose.yml logs kindler-webui-backend
docker compose -f compose/infrastructure/docker-compose.yml logs kindler-webui-frontend

# 重新构建
docker compose -f compose/infrastructure/docker-compose.yml build --no-cache kindler-webui-backend
docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend
```

### 问题 2: 前端无法访问

```bash
# 检查 HAProxy 配置
docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep -A 5 "kindler"

# 检查网络连接
docker inspect kindler-webui-frontend | jq '.[0].NetworkSettings.Networks'

# 测试直接访问前端
curl -I http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kindler-webui-frontend)
```

### 问题 3: API 请求失败

```bash
# 测试后端健康检查
docker exec kindler-webui-backend curl -f http://localhost:8000/api/health

# 检查后端是否可以执行脚本
docker exec kindler-webui-backend ls -l /app/scripts/

# 检查后端是否可以访问 kubectl
docker exec kindler-webui-backend kubectl version --client
```

### 问题 4: WebSocket 连接失败

```bash
# 安装 wscat
npm install -g wscat

# 测试 WebSocket 连接
wscat -c ws://kindler.devops.192.168.51.30.sslip.io/ws/tasks

# 发送测试消息
> {"type": "ping"}

# 应该收到
< {"type": "pong"}
```

## 11. 下一步

✅ **开发完成**，现在可以：

1. **运行回归测试**
   ```bash
   cd /home/cloud/github/hofmannhe/kindler
   scripts/clean.sh --all
   scripts/bootstrap.sh
   # 等待 devops 集群就绪
   # 创建业务集群（通过 Web GUI）
   # 运行完整测试套件
   tests/run_tests.sh all
   ```

2. **同步主分支**
   ```bash
   cd /home/cloud/github/hofmannhe/kindler/worktrees/webui
   git fetch origin
   git merge origin/master
   # 解决冲突（如有）
   git push origin feature/webui
   ```

3. **创建 Pull Request**
   - 在 GitHub/GitLab 上创建 PR
   - 标题: `feat: Add Web GUI for cluster management`
   - 描述: 参考 CHANGELOG_WEBUI.md
   - Reviewer: 项目维护者

4. **Code Review 通过后合并**
   ```bash
   cd /home/cloud/github/hofmannhe/kindler
   git checkout master
   git merge feature/webui
   git push origin master
   ```

5. **更新主仓库文档**
   - 更新 README.md 添加 Web GUI 入口
   - 更新 AGENTS.md 添加 Web GUI 规范
   - 更新 CHANGELOG.md

## 相关文档

- [Web GUI 使用指南](../docs/WEBUI.md)
- [API 测试文档](../webui/tests/README.md)
- [项目 README](../README_CN.md)
- [开发者指南](../AGENTS.md)

