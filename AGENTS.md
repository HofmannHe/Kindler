# Repository Guidelines

本仓库用于维护本地轻量级环境与容器编排：以 Portainer CE 统一管理容器/轻量级集群（kind/k3d 可选），HAProxy 提供统一入口。目标：简单、快速、够用。

## 部署拓扑

### 核心架构
```
┌────────────────────────────────────────────────────────────────┐
│ HAProxy (haproxy-gw)                                           │
│ - 统一网络入口 (192.168.51.30)                                │
│ - 端口暴露:                                                    │
│   *  80 : 域名统一入口（Portainer HTTP→HTTPS、ArgoCD、业务）     │
│   * 443: Portainer HTTPS 透传                                 │
└────────────────────────────────────────────────────────────────┘
           │
           ├──> Portainer CE (portainer-ce)
           │    - Docker Compose 部署
           │    - 管理所有容器和集群
           │    - Edge Agent 模式注册业务集群
           │
           ├──> devops 集群 (k3d)
           │    - 端口映射: 10800:80, 10843:443, 10091:6443
           │    - 内置 Traefik Ingress Controller
           │    - 服务:
           │      * ArgoCD v3.1.7 (GitOps CD 工具)
           │        - 管理所有业务集群的应用部署
           │        - ApplicationSet 动态生成 Applications
           │        - Ingress: argocd.devops.$BASE_DOMAIN
           │      * 外部 Git 仓库（通过 config/git.env 配置）
           │        - 存储应用代码仓库 (如 whoami)
           │        - ArgoCD 监听 Git 变化自动部署
           │    - 全部通过 HAProxy 80 端口基于域名暴露
           │
           └──> 业务集群 (k3d/kind, 按需创建)
                - 通过 create_env.sh 创建
                - 自动注册到 Portainer (Edge Agent)
                - 自动注册到 ArgoCD (kubectl 方式)
                - 通过 HAProxy 80 + 域名路由访问
                - whoami 应用通过 GitOps 自动部署
```

### 核心组件
1. **HAProxy**: 统一入口网关，所有外部访问的唯一入口
2. **Portainer CE**: 容器和集群统一管理界面
3. **devops 集群**: 管理集群，运行 ArgoCD、PostgreSQL、pgAdmin 等 DevOps 和 PaaS 服务
4. **业务集群**: 运行实际应用的 k3d/kind 集群
5. **PaaS 服务**: PostgreSQL 和 pgAdmin 部署在 devops 集群，供所有业务集群使用

### 服务暴露原则（重要）

**核心原则：业务应用必须通过 Ingress 暴露，禁止直接使用 NodePort**

1. **Ingress Controller 本身**
   - ✅ 可以使用 NodePort 暴露（Traefik Service type: NodePort）
   - k3d 集群：serverlb 转发到节点 NodePort (30080)
   - kind 集群：HAProxy 直接访问容器 IP + NodePort (30080)

2. **业务应用**
   - ✅ 必须创建 Ingress 资源，通过 Ingress Controller 路由
   - ✅ Service 类型使用 ClusterIP（集群内部访问）
   - ❌ 禁止使用 NodePort 直接暴露应用
   - ❌ 禁止使用 hostPort 暴露应用

3. **流量路径**
   ```
   外部请求 → HAProxy (80/443)
            ↓
         serverlb:80 (k3d) / 容器IP:30080 (kind)
            ↓
         Traefik Ingress Controller (NodePort 30080)
            ↓
         Ingress 规则匹配
            ↓
         Service (ClusterIP)
            ↓
         Pod
   ```

4. **验收标准**
   - 所有业务应用必须有对应的 Ingress 资源
   - 所有业务应用的 Service 类型必须是 ClusterIP
   - 测试用例必须验证应用通过域名访问（而非 IP:Port）

### GitOps 工作流
- **外部 Git 服务**: 托管应用代码（在 `config/git.env` 中配置）
- **ArgoCD**: 监听 Git 仓库变化，自动部署到集群
- **ApplicationSet**: 从 `config/environments.csv` 动态生成 Applications
- **分支映射**: 分支名与环境名一一对应（如 `dev`、`uat`、`prod`、`dev-k3d` 等），ArgoCD 将分支 `<env>` 的代码同步到集群 `<env>`
- **示例应用**: whoami (仅域名差异，遵循最小化差异原则)

### 网络拓扑
- HAProxy 连接到所有 k3d 集群网络（通过 `docker network connect`）
- Portainer 通过 Edge Agent 模式与业务集群通信
- ArgoCD 通过 ServiceAccount token 连接业务集群 API Server

### 生命周期管理

#### devops 集群（管理集群）
- **创建**: 通过 `bootstrap.sh` 创建，包含 HAProxy、Portainer、ArgoCD、PostgreSQL、pgAdmin
- **清理**: 默认不清理，需要 `clean.sh --all` 或 `clean.sh --include-devops` 才会清理
- **说明**: devops 集群是管理集群，存储所有业务集群的配置和状态，通常保持运行

#### 业务集群
- **创建**: `create_env.sh -n <name> -p kind|k3d` - 自动注册到 Portainer（Edge Agent）和 ArgoCD
- **删除**: `delete_env.sh <name>` - 自动反注册，清理所有相关资源
- **停止**: `stop_env.sh <name>` - 停止集群但保留配置（临时释放资源）
- **启动**: `start_env.sh <name>` - 启动已停止的集群

#### 完整清理
- `clean.sh`: 清理所有业务集群，保留 devops 集群
- `clean.sh --all`: 清理所有环境（包括 devops 集群、容器、网络、数据）

## 语言与沟通
- 文档与日常交流默认使用中文。
- 专业术语、命令、目录路径、代码标识符保留英文原样（如 `k3d`, `Dockerfile`, `kubectl apply`).
- 提交信息与 PR 标题可用中文，但遵循 Conventional Commits 英文前缀（如 `feat:`, `fix:`）。
- 面向外部社区或上游同步时，可附英文摘要（可选）。

## 项目结构与模块组织
- 目录（按需创建）：
  - `images/`：各镜像的 Dockerfile 与构建上下文（如 `images/base/`）。
  - `clusters/`：k3d 集群配置（`*.yaml`）及默认值。
  - `compose/`：Docker Compose（`compose/infrastructure/` 包含 Portainer 与 HAProxy）。
  - `manifests/`：Kubernetes YAML（按需使用）。
  - `scripts/`：辅助脚本；尽量保持 POSIX‑sh 兼容。
  - `examples/`：最小可运行示例。
  - `config/`：环境与密钥（如 `clusters.env`、`secrets.env`）。

## 构建、测试与开发命令
- 启动 Portainer：`scripts/portainer.sh up`（读取 `config/secrets.env` 中 `PORTAINER_ADMIN_PASSWORD`，使用命名卷 `portainer_portainer_data`/`portainer_secrets` 持久化）
- 启动 HAProxy：`docker compose -f compose/infrastructure/docker-compose.yml up -d`（默认对外 `80/443`，可通过 `HAPROXY_HTTP_PORT`/`HAPROXY_HTTPS_PORT` 调整）
- 创建集群：`scripts/create_env.sh -n <env> [-p kind|k3d] [--node-port <port>] [--pf-port <port>] [--register-portainer|--no-register-portainer] [--haproxy-route|--no-haproxy-route]`
  - 默认参数来自 `config/environments.csv`，命令行可覆盖。
  - CSV 列：`env,provider,node_port,pf_port,register_portainer,haproxy_route,http_port,https_port`
  - 版本镜像可通过 `config/clusters.env` 配置：`KIND_NODE_IMAGE`（默认 `kindest/node:v1.31.12`）、`K3D_IMAGE`（默认 `rancher/k3s:stable`）。
- 同步路由：`scripts/haproxy_sync.sh [--prune]`；基础测试：`bats tests`（若安装了 bats）

访问示例：
- Portainer：`http://portainer.devops.$BASE_DOMAIN` → 301 跳转到 `https://portainer.devops.$BASE_DOMAIN`
- ArgoCD：`http://192.168.51.30:23800/` (admin / secrets.env 中配置的密码)

## 编码风格与命名规范
- Dockerfile/YAML：两空格缩进；建议行宽 ~100 列。
- Bash/sh：脚本顶部使用 `set -Eeuo pipefail` 与 `IFS=$'\n\t'`。
- 命名：目录用 `lower-kebab/`；脚本用 `snake_case.sh`；Kubernetes 对象用 `lower-kebab`。
- 格式化/静态检查：`shfmt -w`、`shellcheck`、`yamllint`、`hadolint`。

## 测试指南
- Shell 脚本：在 `tests/` 添加 `bats` 用例；覆盖端口与健康检查。
- 入口验证：
  - Portainer：`curl -kI https://portainer.devops.$BASE_DOMAIN` 为 `200`；`curl -I http://portainer.devops.$BASE_DOMAIN` 为 `301`。
- 轻量集群：按需用 `kubectl get nodes --context <ctx>` 做冒烟校验。

## 回归测试标准

### 测试工具
- **单元测试**: `tests/<module>_test.sh` - 测试特定功能模块
- **E2E 测试**: `tests/e2e_services_test.sh` - 端到端服务可达性测试
- **一致性测试**: `tests/consistency_test.sh` - DB-Git-K8s 一致性验证
- **完整测试套件**: `tests/run_tests.sh all` - 运行所有测试

### 管理服务验收标准

详见 [E2E 服务测试文档](docs/E2E_TEST_VALIDATION_REPORT.md)，关键验收点：

1. **Portainer** (portainer.devops.$BASE_DOMAIN)
   - HTTP 301 重定向到 HTTPS
   - HTTPS 200 访问成功
   - 页面内容包含 "portainer" 关键字（非 ArgoCD）
   - 所有业务集群已注册为 Edge Agent 且状态 online

2. **ArgoCD** (argocd.devops.$BASE_DOMAIN)
   - HTTP 200 访问成功
   - 页面内容包含 "argocd" 关键字
   - 所有业务集群已注册到 ArgoCD
   - 所有 whoami Applications 状态 Healthy

3. **HAProxy Stats** (haproxy.devops.$BASE_DOMAIN/stat)
   - HTTP 200 访问成功
   - 页面包含统计信息

4. **Git Service** (git.devops.$BASE_DOMAIN)
   - HTTP 200/302 访问成功
   - devops 分支存在
   - 所有业务集群对应分支存在

5. **PostgreSQL** (postgresql.paas.svc.cluster.local:5432)
   - Pod 状态 Running
   - 数据库连接正常
   - clusters 表结构正确

### 业务服务验收标准

1. **whoami 应用部署**
   - ArgoCD Application 状态: Synced + Healthy
   - Pod 状态: Running, READY 1/1
   - Service 存在且有 Endpoints
   - Ingress 配置正确 (host: whoami.<env>.$BASE_DOMAIN)

2. **whoami HTTP 可达性**
   - HTTP 200: 应用正常
   - HTTP 404: 路由正常但应用未部署（Git 服务不可用时可接受）
   - HTTP 502/503: 路由或集群异常（失败）

### 集群基础设施验收标准

1. **节点状态**: 所有节点 STATUS=Ready
2. **核心组件**: coredns, kube-proxy Running
3. **Ingress Controller**: Traefik(k3d) 或 ingress-nginx(kind) Running
4. **Edge Agent**: Pod Running, Portainer 状态 online

### 网络与路由验收标准

1. **HAProxy 配置**
   - 每个业务集群有 ACL 定义 (模式: `^[^.]+\.<env>\.[^:]+`)
   - 每个业务集群有 backend 定义
   - 所有路由规则正确

2. **网络连通性**
   - HAProxy 连接到所有 k3d 独立网络
   - devops 集群可访问所有业务集群 API Server

### 一致性验收标准

1. **DB-Git-K8s 一致性**
   - DB 记录、Git 分支、K8s 集群数量相同
   - 集群名称完全匹配，无孤立资源

2. **配置一致性**
   - DB 中的端口配置与实际暴露端口一致
   - DB 中的子网配置与 Docker 网络一致

### 完整测试流程

1. **单次完整测试**
   ```bash
   scripts/clean.sh --all
   scripts/bootstrap.sh
   for cluster in dev uat prod dev-k3d uat-k3d prod-k3d; do
     scripts/create_env.sh -n $cluster
   done
   tests/run_tests.sh all
   ```

2. **三轮回归测试**
   - 执行三次完整测试流程
   - 验收: 三轮全部通过，无任何失败

3. **动态集群增删测试**
   - 创建初始环境
   - 动态添加集群 → 测试
   - 动态删除集群 → 测试
   - 再次添加集群 → 测试
   - 验收: DB-Git-K8s 始终一致

### 测试结果判定

**通过标准**:
- ✅ 所有管理服务可达且内容正确
- ✅ 所有业务服务路由正常 (200 或 404)
- ✅ 所有集群节点 Ready，核心组件 Running
- ✅ Edge Agent 全部 online
- ✅ ArgoCD Applications 全部 Healthy
- ✅ DB-Git-K8s 完全一致
- ✅ 无错误或警告日志

**失败标准**:
- ❌ 任一管理服务不可达或内容错误
- ❌ 业务服务返回 502/503
- ❌ 集群节点 NotReady 或核心组件异常
- ❌ Edge Agent offline 或 error
- ❌ ArgoCD Applications Degraded
- ❌ DB-Git-K8s 不一致
- ❌ 出现错误或警告日志

**警告标准（可接受）**:
- ⚠️ 业务服务返回 404（Git 服务不可用时）
- ⚠️ Git 操作超时但其他步骤成功
- ⚠️ 镜像拉取慢（临时性能问题）

## 测试质量保证规则

### 误报通过的根因分析要求

所有宣称回归测试通过，但在用户验收时发现明显不合格的任务，必须：

1. **深入分析根因**
   - 识别测试用例中的误判逻辑（如只检查状态码不验证内容）
   - 找出被掩盖的错误（如使用 `|| true` 忽略失败）
   - 分析配置错误如何通过测试（如路由错误但状态码正确）

2. **举一反三改进**
   - 修复当前测试用例的验证逻辑
   - 查找其他测试中的类似问题
   - 建立分层验证机制（配置 → 部署 → 访问 → 内容）

3. **更新验收标准**
   - 明确每个测试的通过条件
   - 添加内容验证而非仅状态码
   - 禁止使用宽松的断言（如 `|| true`）

### 测试用例编写原则

1. **精确断言**：明确区分不同的失败原因
   - ✅ 正确：区分 404（应用未部署）vs 502（路由错误）vs 503（服务不可用）
   - ❌ 错误：所有非 200 状态都判定为失败

2. **分层验证**：从配置到最终效果逐层检查
   - ✅ 正确：配置存在 → 资源创建 → 服务运行 → 端口监听 → HTTP 可达 → 内容正确
   - ❌ 错误：只检查最终的 HTTP 状态码

3. **内容验证**：不仅检查状态码，还要验证响应内容
   - ✅ 正确：检查 Portainer 页面包含 "portainer" 关键字
   - ❌ 错误：只检查返回 200 状态码（可能被错误路由到其他服务）

4. **错误透明**：所有失败都应该被准确报告，不得掩盖
   - ✅ 正确：`command || exit 1`（失败时终止并报错）
   - ❌ 错误：`command || true`（忽略所有错误）

### 历史教训

#### 案例 1：Portainer 路由错误被掩盖（2025-10-18）

**问题**：
- 测试显示 Portainer HTTPS 返回 200
- 实际：流量被错误路由到 ArgoCD
- 用户访问 Portainer 域名，看到的是 ArgoCD 界面

**根因**：
1. HAProxy 通配符 ACL `^[^.]+\.devops\.[^:]+` 拦截了所有 devops 子域名
2. 测试只检查 HTTP 状态码，未验证响应内容
3. ArgoCD 和 Portainer 都返回 200，测试无法区分

**修复**：
1. 删除危险的通配符 ACL
2. 在测试中添加内容验证：`curl content | grep -qi "portainer"`
3. 详细记录于 `docs/E2E_TEST_VALIDATION_REPORT.md`

**举一反三**：
- 所有 E2E 测试必须包含内容验证
- 禁止在 HAProxy 动态区域使用通配符 ACL
- 测试失败时必须输出详细的诊断信息

#### 案例 2：whoami Ingress 域名格式错误（2025-10-19）

**问题**：
- 测试显示 whoami 应用可访问
- 实际：Ingress host 配置错误（包含 provider 后缀）
- 用户使用正确域名无法访问

**根因**：
1. ApplicationSet 硬编码参数覆盖了 Git 配置
2. 测试使用错误的域名格式进行验证
3. HAProxy backend 使用了错误的端口（node_port 而非 http_port）

**修复**：
1. 修复 ApplicationSet，移除硬编码参数
2. 更新测试用例使用正确的域名格式
3. 修复 `haproxy_route.sh` 从 CSV 读取正确的 `http_port`
4. 详细记录于 `FINAL_STATUS_REPORT.md`

**举一反三**：
- 测试用例的域名格式必须与实际使用一致
- 避免在 GitOps 流程中使用硬编码覆盖
- 端口配置必须清晰区分（node_port vs http_port）

#### 案例 3：Helm Chart 重复资源定义导致部署失败（2025-10-20）

**问题**：
- ArgoCD 报错 "Resource /Service/whoami/whoami appeared 2 times"
- k3d 集群 Applications 状态: Missing
- 手动 helm template 渲染显示重复的 Service 定义

**根因**：
1. Git 仓库 `deploy/templates/deployment.yaml` 包含了 Service 定义
2. `deploy/templates/service.yaml` 也定义了相同的 Service
3. Helm 渲染时产生两个完全相同的资源
4. ArgoCD 无法处理重复资源导致同步失败

**修复**：
1. 从 `deployment.yaml` 中删除 Service 和 Namespace 定义
2. 只保留独立的 `service.yaml` 文件
3. 确保每个模板文件只定义一种资源类型
4. 使用 `helm template` 验证渲染结果

**举一反三**：
- Helm Chart 模板结构要清晰：每个文件只定义一种资源类型
- 使用 `helm template` 在提交前验证渲染结果
- 对比 Git 仓库不同分支的配置差异
- 简化问题分析：从最基本的配置开始检查
- 避免在 `deployment.yaml` 中包含多种资源类型

**诊断方法**：
```bash
# 手动渲染 Helm Chart 检查重复资源
helm template whoami deploy/ | grep -B 5 "kind: Service"
# 应该只看到一个 Service 定义，来自 service.yaml

# 检查不同分支的差异
git diff dev..dev-k3d -- deploy/templates/
```

#### 案例 4：测试用例假设与实际实现不一致（2025-10-20）

**问题**：
- 三轮回归测试显示多个失败
- 但所有业务服务实际 HTTP 200 正常访问
- 测试报告显示域名不匹配、端口不匹配等问题

**根因**：
1. 测试用例假设域名格式为 `whoami.<env>.xxx`（去掉 provider 后缀）
2. 实际实现使用完整集群名 `whoami.<cluster>.xxx`（包含 -k3d/-kind）以避免 HAProxy ACL 冲突
3. 测试用例在多个文件中重复了相同的错误假设
4. 测试用例未考虑不同 provider 的实现差异（kind 用容器IP+NodePort，k3d 用 host 端口映射）

**修复**：
1. 更新 5 个测试文件中的域名期望逻辑，使用完整集群名
   - `tests/ingress_test.sh`
   - `tests/haproxy_test.sh`
   - `tests/ingress_config_test.sh`
   - `tests/e2e_services_test.sh`
   - `tests/services_test.sh`
2. 将 `env_name="${cluster%-k3d}"; env_name="${env_name%-kind}"` 改为直接使用 `$cluster`
3. 更新所有相关的输出信息和错误提示

**举一反三**：
- **测试用例必须与实际实现保持一致**，不能基于错误的假设
- **大规模修改后必须验证测试用例**，确保测试预期匹配新实现
- **避免在多个文件中重复相同的逻辑**，考虑提取公共函数
- **测试失败不一定是系统问题**，也可能是测试用例本身的问题
- **测试用例应该灵活适应不同的实现方式**（如根据 provider 类型判断）
- **文档和测试用例同步更新**，避免不一致

**验证方法**：
```bash
# 三轮回归测试验证一致性
for i in 1 2 3; do
  echo "=== Round $i ==="
  tests/run_tests.sh all
  sleep 5
done

# 验证所有集群 HTTP 可达性
for cluster in dev uat prod dev-k3d uat-k3d prod-k3d; do
  curl -s -o /dev/null -w "%{http_code}" http://whoami.$cluster.192.168.51.30.sslip.io
done
```

**关键教训**：
- 当测试显示失败但实际功能正常时，优先检查测试用例的假设是否正确
- 修复系统实现后，必须同步更新测试用例的预期
- 使用 `grep` 等工具全局搜索可能受影响的测试文件
- 三轮回归测试是发现测试用例问题的有效方法（结果一致性验证）

### 禁止的测试反模式

1. **忽略错误**: `command || true`
2. **宽松断言**: 只检查状态码不验证内容
3. **硬编码假设**: 假设特定的集群名称或域名
4. **跳过验证**: 不检查中间状态，只看最终结果
5. **误导性成功**: 测试通过但功能实际失败

### 推荐的测试模式

1. **明确失败分类**: 使用不同的退出码区分不同失败原因
2. **详细错误信息**: 失败时输出诊断信息和修复建议
3. **幂等性验证**: 测试可以安全地重复运行
4. **依赖明确**: 清楚声明测试的前置条件
5. **隔离性**: 测试之间不互相影响

## 测试固化原则（2025-10 新增）

### 核心要求

**所有测试过程中发现的问题必须通过自动化测试固化，防止回归。**

### 实施标准

1. **问题必现性（TDD 红-绿-重构）**
   - 每个 bug 修复前，先编写能复现该 bug 的测试用例
   - 测试用例应失败（红灯）- 证明问题存在
   - 修复代码使测试通过（绿灯）
   - 重构优化（保持绿灯）

2. **详细诊断输出**
   
   测试失败时必须输出：
   - **Expected（期望值）**: 应该是什么
   - **Actual（实际值）**: 实际是什么
   - **Context（上下文）**: 集群名称、配置参数、环境变量等
   - **Fix Suggestion（修复建议）**: 如何解决该问题
   
   示例：
   ```bash
   echo "✗ Test Failed: Database insert cluster"
   echo "  Expected: Cluster 'dev' record in database"
   echo "  Actual: No records found in clusters table"
   echo "  Context: provider=k3d, node_port=30080"
   echo "  Fix: Check if server_ip column exists in clusters table"
   echo "  Command: kubectl exec postgresql-0 -- psql -U kindler -d kindler -c '\d clusters'"
   ```

3. **测试命名规范**
   - 格式：`test_<功能模块>_<具体场景>`
   - 好的示例：
     * `test_db_insert_cluster_with_server_ip`
     * `test_webui_api_delete_devops_returns_403`
     * `test_cluster_create_records_to_database`
   - 坏的示例：
     * `test1` - 无意义
     * `test_db` - 太宽泛
     * `test_bug_fix` - 不明确

4. **测试覆盖要求**
   - 每个脚本的关键路径必须有测试覆盖
   - WebUI 的每个 API endpoint 必须有测试
   - 数据库操作必须有测试（CRUD 全覆盖）
   - 边界条件必须测试（空值、特殊字符、并发）

5. **测试独立性与清理**
   - 每个测试应独立运行，不依赖其他测试
   - 测试前设置环境（setup），测试后清理副作用（teardown）
   - 使用唯一标识避免冲突（如测试集群名加时间戳）

6. **禁止的测试反模式**（扩展版）
   - ❌ 问题修复后不添加测试（导致回归）
   - ❌ 测试失败但静默忽略（`|| true`、`2>/dev/null || :`）
   - ❌ 测试只检查退出码，不检查实际效果
   - ❌ 测试没有清理副作用（影响后续测试）
   - ❌ 测试有副作用但不声明（如修改全局配置）
   - ❌ 硬编码期望值而不从配置读取

7. **测试执行与集成**
   - 所有测试必须集成到 `tests/run_tests.sh`
   - 测试应支持单独运行和批量运行
   - 测试失败时返回非零退出码
   - 测试输出应易于解析（支持 TAP 或 JSON 格式）

### 历史教训

#### 案例 5：数据库表结构不一致导致集群未记录（2025-10-24）

**问题**：
- 集群创建成功，Kubernetes 运行正常
- 数据库中无集群记录，WebUI 看不到集群
- 测试显示通过，但实际功能失效

**根因**：
- `init_database.sh` 创建表时缺少 `server_ip` 列
- `lib_db.sh` 插入时使用了 `server_ip` 列
- SQL 执行失败，但错误被不当处理
- 无测试覆盖数据库插入操作

**修复**：
1. 添加 `tests/db_operations_test.sh` 测试数据库 CRUD
2. 在 `init_database.sh` 中添加 `server_ip` 列
3. 改进 `create_env.sh` 的错误处理，记录详细错误
4. 添加集群创建后的数据库验证测试

**举一反三**：
- 所有数据库表结构变更必须有对应的测试验证
- 数据库操作失败不得静默忽略，必须记录详细错误
- 测试必须验证最终效果（如数据库有记录），而非仅检查脚本退出码
- 所有关键路径的失败都应有明确的诊断输出

#### 案例 6：测试跳过导致虚假成功 - WebUI 创建集群功能问题（2025-10-24）

**问题**：
- 声称 WebUI 功能完成并通过测试
- 但测试实际被跳过（"WebUI not accessible"）
- 用户验收时发现"创建集群就不对"

**深层问题**（三层）：
1. **配置层**：HAProxy 域名配置错误（`kindler.devops.xxx` vs `webui.devops.xxx`）
2. **API 设计层**：强制要求端口参数（pf_port, http_port, https_port 为必需字段）
3. **数据层**：代码尝试插入 `status` 列，但数据库表中无此列

**根因**：
- 测试跳过时未追问"为什么跳过"
- 接受"WebUI 未部署"作为理由，而非立即部署
- 过早声称任务完成（代码编写 ≠ 功能完成）
- 只验证代码层，忽略配置层、网络层、数据层

**修复**：
1. 部署 WebUI（满足测试前置条件）
2. 修正 HAProxy 配置（域名规范化：webui.devops.xxx）
3. 端口字段改为 Optional + 自动分配逻辑（UX 优化）
4. 从数据库 INSERT 语句中删除 `status` 列
5. 重新运行测试：7/7 全部通过

**举一反三**：
- **测试跳过 ≠ 测试通过**，跳过意味着前置条件缺失，必须补充
- **完成 = 所有测试通过 + 用户验收通过**，而非仅代码编写完成
- **分层验证**：配置层 → 网络层 → API 层 → 数据层 → UI 层，每层都要验证
- **API 设计要考虑 UX**：自动化优于手动，减少用户输入
- **代码与环境同步**：修改代码 → 更新配置 → 更新数据库 → 更新测试

**禁止的测试反模式（扩展）**：
- ❌ 测试跳过但声称任务完成
- ❌ 只验证最上层（UI/API），忽略底层（配置/数据库）
- ❌ 修改代码后不重新运行测试
- ❌ 接受虚假的成功（测试未运行但声称通过）
- ❌ 声称"待验证"但从不真正验证

**诊断方法**：
```bash
# 1. 部署依赖
cd webui && docker compose up -d

# 2. 验证网络层
curl -I http://webui.devops.192.168.51.30.sslip.io

# 3. 运行测试
tests/webui_api_test.sh

# 4. 深度诊断失败
docker logs kindler-webui-backend --tail 50

# 5. 验证数据库
kubectl exec postgresql-0 -- psql -U kindler -d kindler -c "\d clusters"
```

## 超时机制与防卡死准则

### 核心原则

**所有可能阻塞的操作必须设置合理的超时时间**，防止脚本或测试卡死导致任务无限期等待。

### 常见需要超时保护的操作

1. **网络请求**
   ```bash
   # ✓ 正确：使用 timeout 或 curl -m
   timeout 5 curl -s http://example.com
   curl -s -m 10 http://example.com
   
   # ✗ 错误：无超时保护
   curl -s http://example.com
   ```

2. **Kubernetes 资源等待**
   ```bash
   # ✓ 正确：使用 --timeout
   kubectl wait --for=condition=ready pod/nginx --timeout=60s
   kubectl delete namespace test --timeout=30s
   
   # ✗ 错误：无超时限制
   kubectl wait --for=condition=ready pod/nginx
   ```

3. **ArgoCD 同步等待**
   ```bash
   # ✓ 正确：分段检查 + 最大次数限制
   for i in {1..12}; do  # 最多等待 60 秒
     status=$(kubectl get application app -o jsonpath='{.status.sync.status}')
     [ "$status" = "Synced" ] && break
     sleep 5
   done
   
   # ✗ 错误：无限等待
   while true; do
     status=$(kubectl get application app -o jsonpath='{.status.sync.status}')
     [ "$status" = "Synced" ] && break
     sleep 5
   done
   ```

4. **容器/集群启动**
   ```bash
   # ✓ 正确：使用重试次数限制
   max_retries=30
   for i in $(seq 1 $max_retries); do
     kubectl get nodes && break || sleep 2
   done
   
   # ✗ 错误：无限循环
   until kubectl get nodes; do sleep 2; done
   ```

5. **Namespace 删除**
   ```bash
   # ✓ 正确：超时 + 强制清理 finalizers
   kubectl delete namespace test --timeout=30s || {
     echo "Timeout, force cleaning..."
     kubectl get namespace test -o json | \
       jq '.spec.finalizers = []' | \
       kubectl replace --raw /api/v1/namespaces/test/finalize -f -
   }
   
   # ✗ 错误：可能卡在 Terminating 状态
   kubectl delete namespace test
   ```

6. **Git 操作**
   ```bash
   # ✓ 正确：使用 timeout 包装
   timeout 30 git clone https://example.com/repo.git
   
   # ✗ 错误：网络问题可能导致无限等待
   git clone https://example.com/repo.git
   ```

7. **测试套件执行**
   ```bash
   # ✓ 正确：整体超时保护
   timeout 300 tests/run_tests.sh all  # 5分钟超时
   
   # ✗ 错误：无超时可能导致 CI/CD 卡死
   tests/run_tests.sh all
   ```

### 推荐超时时间

| 操作类型 | 推荐超时 | 说明 |
|---------|---------|------|
| HTTP 请求 | 5-10秒 | 管理服务访问 |
| kubectl wait | 60-300秒 | Pod/Deployment 就绪 |
| kubectl delete | 30-60秒 | 资源删除 |
| 集群创建 | 180秒 | k3d/kind 集群启动 |
| ArgoCD sync | 60-120秒 | Application 同步 |
| Git clone/push | 30-60秒 | 代码仓库操作 |
| 完整测试套件 | 300-600秒 | 回归测试 |
| 单个测试模块 | 60-120秒 | 模块测试 |

### 超时后的处理策略

1. **记录详细日志**: 超时时输出当前状态和诊断信息
2. **尝试清理**: 执行必要的资源清理（如删除卡住的 namespace）
3. **明确报告**: 清楚说明超时原因和建议的修复方法
4. **非零退出码**: 确保超时被正确识别为失败

### 示例：完整的超时保护模式

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# 1. HTTP 请求超时
echo "Testing service..."
if ! timeout 10 curl -f -s http://example.com >/dev/null; then
  echo "✗ Service timeout or unreachable after 10s"
  exit 1
fi

# 2. K8s 资源等待超时
echo "Waiting for pod..."
if ! kubectl wait --for=condition=ready pod/nginx --timeout=60s; then
  echo "✗ Pod not ready after 60s"
  kubectl describe pod/nginx  # 输出诊断信息
  exit 1
fi

# 3. ArgoCD 同步超时
echo "Waiting for ArgoCD sync..."
max_attempts=12
for i in $(seq 1 $max_attempts); do
  status=$(kubectl get application app -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  if [ "$status" = "Synced" ]; then
    echo "✓ Synced after $((i*5))s"
    break
  fi
  if [ $i -eq $max_attempts ]; then
    echo "✗ Sync timeout after ${max_attempts}0s"
    kubectl get application app -o yaml | grep -A 10 "conditions:"
    exit 1
  fi
  sleep 5
done

# 4. Namespace 删除超时处理
echo "Deleting namespace..."
if ! kubectl delete namespace test --timeout=30s 2>/dev/null; then
  echo "⚠ Delete timeout, force cleaning finalizers..."
  kubectl get namespace test -o json 2>/dev/null | \
    jq '.spec.finalizers = []' | \
    kubectl replace --raw /api/v1/namespaces/test/finalize -f - || true
  echo "✓ Force clean completed"
fi

echo "✓ All operations completed successfully"
```

### 测试脚本超时准则

1. **单个断言**: 3-5秒（HTTP 请求）
2. **测试用例**: 30-60秒（包含多个断言）
3. **测试模块**: 60-120秒（包含多个用例）
4. **完整套件**: 300-600秒（所有模块）

### CI/CD 超时配置

```yaml
# GitHub Actions 示例
jobs:
  test:
    timeout-minutes: 15  # 整体任务超时
    steps:
      - name: Run Tests
        timeout-minutes: 10  # 步骤超时
        run: timeout 600 tests/run_tests.sh all
```

## 提交与 Pull Request 规范
- 使用 Conventional Commits：`feat:`、`fix:`、`chore:`、`docs:`、`ci:`、`refactor:`。
- 提交应小而聚焦；说明“为什么”而不仅是“做了什么”。
- PR 必须包含：动机、变更摘要、测试方法（命令）、必要的截图/日志，并关联相关 issue。

## 安全与配置提示
- 禁止提交密钥；提供 `*.example` 文件，并在 `.gitignore` 忽略真实值。
- `config/git.env` 仅保存本地仓库凭证，请使用 `config/git.env.example` 模板并避免提交真实值。
- 尽量使用镜像摘要固定基镜像；避免在生产路径使用 `latest`。
- 配置以环境变量为主，避免硬编码；记录必需变量。

## Agent 专用说明
- 域名命名统一遵循 `[service].[env].[BASE_DOMAIN]` 规则；系统保留集群使用 `devops` 作为 env，例如 `portainer.devops.192.168.51.30.sslip.io`、`haproxy.devops.192.168.51.30.sslip.io/stat`、`argocd.devops.192.168.51.30.sslip.io`、`whoami.devk3d.192.168.51.30.sslip.io`。
- 每次修改后必须验证：至少使用 curl（必要时配合浏览器/MCP 浏览器）验证基础环境与域名路由；并运行 `scripts/smoke.sh <env>` 记录到 `docs/TEST_REPORT.md`（强制要求）。
- 遵循本 AGENTS.md 对其目录树内文件的要求。
- 提前给出简短计划，保持改动最小，避免破坏性命令。
- 对改动文件执行格式化/静态检查；统一通过 `scripts/*` 入口脚本暴露操作，避免新增 Makefile 目标。
- 项目目标是创建一个Portainer+HAProxy为核心的基础环境，然后根据用户提供的配置清单拉起指定的环境，拉起的环境需要被基础环境的Portainer管理，且在HAProxy中为其创建了路由，便于用户访问其中的服务
- 每轮修改都需要遵循以下验收标准：
1. 先执行clean.sh，然后执行bootstrap.sh拉起基础集群
2. 执行create_env.sh,创建environments.csv中的虚拟环境，其中kind至少三个，k3d至少三个
3. 确保拉起的集群功能正常，能被portainer管理，且全程无报错和警告
- 已经确认Edge Agent适合当前模式，注意不要又反复退回去尝试普通Agent
- 当最小基准建立之后，要严格遵循最小变更原则，非必要不变更
- 每次修订README等文档的时候需要同时修订中英文版本
- devops集群不应该部署whoami服务，应该部署到其它业务集群上。另外注意这些集群名称包括域名不应存在硬编码，因为环境配置csv中的环境名称是可能增删改的，测试用例也需要覆盖环境名增删改

## 诊断与维护工具

### 一致性检查
```bash
# 全面检查 DB、Git、K8s 三者一致性
scripts/check_consistency.sh

# 输出示例：
# ✓ DB: 6 clusters
# ✓ Git: 6 branches (dev, uat, prod, dev-k3d, uat-k3d, prod-k3d)
# ✓ K8s: 6 clusters running
# ✗ Inconsistency found:
#   - Cluster 'test' in DB but Git branch missing
#   - Git branch 'old-env' exists but not in DB
#   Suggested fix: scripts/sync_git_from_db.sh
```

### Git 同步修复
```bash
# 根据 DB 重建所有 Git 分支
scripts/sync_git_from_db.sh

# 使用场景：
# - Git 操作失败后修复
# - 手动删除了分支需要恢复
# - 批量清理临时分支后重建
```

### 环境列表
```bash
# 查看所有环境（从 DB 读取，fallback 到 CSV）
scripts/list_env.sh

# 输出：
# NAME       PROVIDER  SUBNET          NODE_PORT  HTTP_PORT  STATUS
# dev        kind      N/A             30080      18090      Running
# dev-k3d    k3d       10.101.0.0/16   30080      18091      Running
```

### 清理孤立资源
```bash
# 清理 Git 中不在 DB 的分支
scripts/cleanup_orphaned_branches.sh

# 清理 K8s 中不在 DB 的集群
scripts/cleanup_orphaned_clusters.sh
```

## 开发模式（Git Flow + Git Worktree）

- 目标：实现“部署与开发隔离”。项目根目录仅承载 `master`（或 `main`）稳定分支，供用户直接使用与部署；开发分支使用 `git worktree` 挂载到本地 `worktrees/` 目录下。
- 目录规范：
  - 在项目根目录创建 `worktrees/`（已加入 `.gitignore`），该目录不纳入版本控制。
  - `worktrees/<branch-name>/` 对应一个开发分支的工作树。
- 使用示例：
  ```bash
  # 准备本地工作树根目录（已在 .gitignore 中忽略）
  mkdir -p worktrees

  # 创建并挂载新特性分支（基于 master/main）
  git worktree add worktrees/feature-x feature/x

  # 切换到工作树开发
  cd worktrees/feature-x
  # 开发、提交、推送...

  # 回到主仓部署目录（master/main），不受工作树改动影响
  cd ../../  # 返回项目根目录

  # 完成后移除工作树
  git worktree remove worktrees/feature-x
  git branch -D feature/x   # 如需删除分支
  ```
- 约束：
  - 所有部署脚本、CI/测试不得依赖 `worktrees/` 内容；生产使用始终以根目录的 `master/main` 为准。
  - 文档/脚本若需说明开发流程，统一指向 `git worktree` 方式；避免在根目录创建临时开发文件。

## GitOps 合规要求

### 核心原则
- **除 ArgoCD 本身外，所有 Kubernetes 应用必须由 ArgoCD 管理**
- **禁止使用 `kubectl apply` 直接部署应用**（ArgoCD 安装除外）
- **配置变更必须通过 Git 提交触发**

### 合规检查
- 所有应用部署必须有对应的 ArgoCD Application 或 ApplicationSet
- 应用配置存储在外部 Git 仓库（`config/git.env` 配置）
- 使用 `scripts/check_gitops_compliance.sh` 检查合规性

### 例外情况
- ArgoCD 本身的安装和配置（通过 `scripts/setup_devops.sh`）
- 临时调试用途（需在调试完成后清理）

## PaaS 服务规范

### PostgreSQL
- **部署位置**: devops 集群的 `paas` namespace
- **用途**: 存储集群配置信息（clusters 表）
- **访问方式**: 集群内通过 `postgresql.paas.svc.cluster.local:5432`
- **管理方式**: 由 ArgoCD 管理，配置存储在外部 Git 仓库

### pgAdmin
- **部署位置**: devops 集群的 `paas` namespace
- **访问地址**: `https://pgadmin.devops.192.168.51.30.sslip.io`
- **用途**: PostgreSQL 数据库管理界面
- **管理方式**: 由 ArgoCD 管理，通过 Traefik Ingress 暴露

### 集群配置管理（2025-10 更新）

#### 配置数据源优先级
1. **PostgreSQL（唯一真实来源）**
   - 所有业务集群配置存储在 `paas.clusters` 表
   - 字段：name, provider, subnet, node_port, pf_port, http_port, https_port
   - 通过 `scripts/lib_db.sh` 提供 CRUD 操作

2. **environments.csv（过渡 Fallback）**
   - 仅在数据库不可用时使用
   - 未来版本将完全移除
   - 不得手动编辑（由脚本自动生成）

3. **外部 Git 分支（衍生数据）**
   - 每个业务集群对应一个同名分支（如 dev, uat, prod, dev-k3d）
   - 分支内包含 whoami 应用的 Helm Chart manifests
   - **禁止手动创建/删除分支**，必须由脚本管理

#### 分支管理规则
- **创建时机**: `create_env.sh` 执行时自动创建对应 Git 分支
- **删除时机**: `delete_env.sh` 执行时自动删除对应 Git 分支
- **命名规则**: 分支名 = 集群名（直接使用 DB 中的 `name` 字段）
- **保留分支**: 仅保留项目管理分支（main, develop, release）和 devops 分支
- **临时分支**: 测试分支（如 rttr-*）应及时清理

#### 操作流程
1. **创建集群**:
   ```bash
   scripts/create_env.sh -n <name> -p <provider>
   # 自动执行：
   # 1. 检查 DB 中是否已存在
   # 2. 插入 DB 记录
   # 3. 创建 Git 分支（含 whoami manifests）
   # 4. 创建 K8s 集群
   # 5. 注册到 Portainer/ArgoCD
   # 6. 添加 HAProxy 路由
   ```

2. **删除集群**:
   ```bash
   scripts/delete_env.sh -n <name>
   # 自动执行：
   # 1. 删除 K8s 集群
   # 2. 反注册 Portainer/ArgoCD
   # 3. 删除 HAProxy 路由
   # 4. 删除 Git 分支
   # 5. 删除 DB 记录
   ```

3. **一致性检查**:
   ```bash
   scripts/check_consistency.sh
   # 检查 DB、Git、K8s 三者一致性
   # 输出不一致项和修复建议
   ```

4. **同步修复**:
   ```bash
   scripts/sync_git_from_db.sh
   # 根据 DB 记录重建所有 Git 分支
   # 用于 Git 操作失败后的修复
   ```

#### 错误处理原则
- **Git 操作失败**: 显示详细错误，提示用户检查 Git 服务和凭证
- **DB 操作失败**: 显示 SQL 错误，提示用户检查 devops 集群和 PostgreSQL
- **部分失败**: 记录中间状态，提供恢复命令
- **用户手动介入**: 低频操作允许手动修复，脚本提供清晰指引
