# Claude AI 助手使用规则

> **适用范围**：所有使用 Claude（包括 Cursor、API等）参与 Kindler 项目开发的场景

---

## 核心原则

### 0. 长耗时任务与网络保活（强制执行）

**问题背景**：当前系统网络环境要求保活连接，长时间无输出（>30秒）会导致网络连接中断，任务被迫终止。

**强制要求**：所有预期耗时超过30秒的操作，必须使用定期进度输出模式。

#### 标准模式

```bash
# 模式1：后台任务 + 定期检查
command > /tmp/output.log 2>&1 &
PID=$!
sleep 60 && echo "进度: $(date)" && tail -50 /tmp/output.log | grep "关键字" | tail -20

# 模式2：循环监控
for i in {1..10}; do
  sleep 30
  echo "进度检查 $i/10: $(date)"
  tail -20 /tmp/output.log | grep -E "Status|Progress|✓|✗"
done

# 模式3：回归测试专用
tests/run_tests.sh all > /tmp/test_$(date +%s).log 2>&1 &
sleep 120 && echo "进度: $(date)" && \
  tail -120 /tmp/test_*.log | \
  grep -E "^#|^Running|Test Summary|Status.*✓|Status.*✗" | tail -25
```

#### 核心要点

1. **输出频率**：每 30-60 秒输出一次进度
2. **时间戳**：每次输出必须包含 `$(date)`
3. **有意义信息**：使用 `tail + grep` 过滤关键进度信息
4. **适用场景**：
   - 完整回归测试（~8分钟）
   - 集群创建/删除（~30-60秒）
   - ArgoCD 同步等待（>30秒）
   - 大批量数据处理

#### 错误示例 ❌

```bash
# 错误：直接执行，无进度输出
tests/run_tests.sh all

# 错误：sleep 太长，无中间输出
sleep 300 && check_status
```

#### 正确示例 ✅

   ```bash
# 正确：定期输出进度
tests/run_tests.sh all > /tmp/test.log 2>&1 &
sleep 120 && echo "进度 [1/3]: $(date)" && tail -30 /tmp/test.log | grep -E "Test Summary|Status"
sleep 120 && echo "进度 [2/3]: $(date)" && tail -30 /tmp/test.log | grep -E "Test Summary|Status"
wait
echo "完成: $(date)" && cat /tmp/test.log
```

---

### 1. 测试自动化与幂等性（零容忍手动操作）

**最高优先级规则**：**任何需要手动干预的测试流程都视为失败，必须立即修正。**

#### 禁止的行为（零容忍）

1. ❌ **声称"测试通过"但实际需要手动清理**
   - 这是最严重的违反
   - 即使只需要一个手动命令也是失败
   - 必须立即修正，重新测试

2. ❌ **要求用户手动运行清理脚本**
   - 示例：`tests/cleanup_test_clusters.sh`
   - 测试应该自动包含所有必要的清理

3. ❌ **要求用户手动删除资源**
   - 示例：手动删除孤立的 ArgoCD secrets
   - 测试应该是幂等的，可重复执行

4. ❌ **要求用户手动验证结果**
   - 示例：让用户运行 `kubectl get` 检查资源
   - 测试应该自动验证所有结果

5. ❌ **接受"测试跳过"作为成功**
   - 跳过意味着前置条件缺失
   - 必须补充前置条件或修复测试

#### 正确的做法（强制执行）

1. ✅ **测试包含完整的前置清理**
```bash
   # tests/run_tests.sh all
   scripts/clean.sh --all       # 彻底清理
   scripts/bootstrap.sh         # 重建环境
   verify_initial_state         # 验证就绪
   run_all_tests                # 执行测试
   verify_final_state           # 验证结果
   ```

2. ✅ **测试失败立即停止（fail-fast）**
```bash
   set -e  # 任何失败立即退出
   for test in services ingress ...; do
     run_test "$test" || exit 1  # 失败立即停止
   done
   ```

3. ✅ **防御性清理保证幂等性**
```bash
   # 每个E2E测试开始前
   if cluster_exists "$name"; then
     delete_cluster "$name"     # 先清理已存在的
   fi
   create_cluster "$name"       # 再创建
   ```

4. ✅ **自动验证资源状态**
   ```bash
   # 测试结束后自动验证
   verify_preserved_clusters    # test-api-*
   verify_deleted_clusters      # test-e2e-*
   verify_no_orphaned           # 无孤立资源
   ```

---

### 2. 验收标准

#### "测试通过"的定义

**"测试通过" = 以下全部满足（缺一不可）**：

1. ✅ **从零状态开始**
   - 执行 `scripts/clean.sh --all`
   - 清理所有集群、容器、网络、数据

2. ✅ **自动初始化**
   - 执行 `scripts/bootstrap.sh`
   - 创建 devops 集群和预置业务集群
   - 无需任何手动干预

3. ✅ **所有测试执行**
   - 执行 `tests/run_tests.sh all`
   - 无需任何手动操作
   - 失败立即停止

4. ✅ **结果自动验证**
   - 所有断言通过
   - 预期资源存在
   - 无孤立资源（除预期保留的）

5. ✅ **可重复执行**
   - 多次运行结果一致
   - 幂等性保证

6. ✅ **文档清晰**
   - 用户可以独立验证
   - 提供验证命令

#### 错误的验收标准示例

❌ **错误示例 1**：
```
测试通过！（但需要先运行 cleanup_test_clusters.sh 清理孤立资源）
```
**问题**：需要手动清理

❌ **错误示例 2**：
```
测试通过！（请手动验证 Portainer 中没有孤立 endpoints）
```
**问题**：需要手动验证

❌ **错误示例 3**：
```
测试跳过，因为 WebUI 未部署。
```
**问题**：接受跳过作为成功

✅ **正确示例**：
```
$ tests/run_tests.sh all
[1/5] Cleanup: Removing all clusters...
[2/5] Bootstrap: Creating devops + preset clusters...
[3/5] Verify: Checking initial environment...
[4/5] Test: Running all test suites (fail-fast)...
[5/5] Verify: Checking final environment...

========================================
  Test Results
========================================
Total:   156
Passed:  156
Failed:  0
Status: ✓ ALL TEST SUITES PASSED

Preserved clusters for inspection:
  - test-api-k3d-12345 (k3d)
  - test-api-kind-12345 (kind)
```

---

### 3. 三层幂等性保证

#### 第一层：测试套件级别

**范围**：`tests/run_tests.sh all`

**实现**：
```bash
case "$target" in
  all)
    # [1/5] 彻底清理
    scripts/clean.sh --all || exit 1
    
    # [2/5] 重建环境
    scripts/bootstrap.sh || exit 1
    
    # [3/5] 验证初始状态
    verify_initial_state || exit 1
    
    # [4/5] 执行测试（fail-fast）
    set -e
    for test in services ingress ...; do
      run_test "$test"
    done
    set +e
    
    # [5/5] 验证最终状态
    verify_final_state
    ;;
esac
```

**验证标准**：
- ✅ 从任意初始状态开始都能通过
- ✅ 多次运行结果一致
- ✅ 无需任何手动操作

#### 第二层：单个测试套件级别

**范围**：如 `tests/webui_api_test.sh`

**实现**：
```bash
main() {
  # 基础测试（只读，无副作用）
  test_api_list_clusters_200
  test_api_get_cluster_detail_200 "devops"
  
  # E2E 测试（创建4个集群：k3d+kind各2个）
  test_api_create_cluster_e2e "k3d" "test-api-k3d-$$" "preserve"
  test_api_create_cluster_e2e "kind" "test-api-kind-$$" "preserve"
  test_api_create_cluster_e2e "k3d" "test-e2e-k3d-$$" "delete"
  test_api_delete_cluster_e2e "test-e2e-k3d-$$"
  test_api_create_cluster_e2e "kind" "test-e2e-kind-$$" "delete"
  test_api_delete_cluster_e2e "test-e2e-kind-$$"
  
  # 汇总（明确哪些保留）
  echo "Preserved clusters for inspection:"
  echo "  - test-api-k3d-$$"
  echo "  - test-api-kind-$$"
}
```

**验证标准**：
- ✅ 创建4个集群（k3d+kind各2个）
- ✅ 保留2个供查看（test-api-*）
- ✅ 删除验证2个（test-e2e-*）
- ✅ 无孤立资源

#### 第三层：单个 E2E 用例级别

**范围**：如 `test_api_create_cluster_e2e()`

**实现**：
```bash
test_api_create_cluster_e2e() {
  local provider="$1"
  local cluster_name="$2"
  local action="$3"
  
  # [幂等性保证1] 防御性清理
  if cluster_exists "$cluster_name"; then
    echo "  [IDEMPOTENT] Cluster exists, deleting first..."
    delete_cluster "$cluster_name"
  sleep 5
  fi
  
  # [幂等性保证2] 数据库清理
  kubectl exec postgresql-0 -- psql ... \
    -c "DELETE FROM clusters WHERE name='$cluster_name';"
  
  # [幂等性保证3] ArgoCD 清理
  kubectl delete secret "cluster-$cluster_name" -n argocd || true
  
  # [幂等性保证4] Portainer 清理
  scripts/portainer.sh del-endpoint "$(echo $cluster_name | sed 's/-//g')" || true
  
  # 执行创建...
  create_cluster "$cluster_name" "$provider"
  
  # 验证所有资源...
  verify_all_resources "$cluster_name"
}
```

**验证标准**：
- ✅ 唯一命名（使用 $$ 或 timestamp）
- ✅ 防御性清理（5层：K8s + DB + ArgoCD + Git + Portainer）
- ✅ trap 机制（异常时也清理）
- ✅ 可重复执行

---

### 4. 失败处理策略

#### Fail-Fast 原则

**规则**：第一个测试失败时立即停止，不继续执行。

**理由**：
1. 后续测试可能依赖前面的环境
2. 避免级联失败掩盖真正的问题
3. 保留现场供调试

**实现**：
   ```bash
# 方法1：使用 set -e
set -e
test1 || exit 1
test2 || exit 1
test3 || exit 1

# 方法2：检查返回值
if ! test1; then
  echo "✗ test1 failed, stopping..."
  exit 1
   fi
   ```

#### 现场保留

**失败时保留**：
- K8s 集群状态
- 数据库内容
- 日志文件
- 配置文件

**不要自动清理**：
- 失败的集群
- 中间状态的资源
- 错误日志

**提供诊断信息**：
   ```bash
echo "✗ Test failed: $test_name"
echo "  Expected: $expected"
echo "  Actual: $actual"
echo "  Context: cluster=$cluster, provider=$provider"
echo "  Fix: Check logs with: kubectl logs ..."
echo "  Debug: kubectl --context $ctx get pods -A"
```

---

### 5. 常见错误模式与修正

#### 错误模式 1：事后清理

❌ **错误**：
```
# 测试完成后
echo "测试通过！"
echo "请运行以下命令清理测试资源："
echo "  tests/cleanup_test_clusters.sh"
```

✅ **正确**：
```
# 测试包含自动清理
cleanup() {
  for cluster in test-e2e-*; do
    delete_cluster "$cluster"
  done
}
trap cleanup EXIT

# 测试完成后
verify_no_orphaned_resources
echo "✓ All tests passed (auto-cleaned)"
```

#### 错误模式 2：接受跳过

❌ **错误**：
```
if ! webui_accessible; then
  echo "⚠ WebUI not accessible, skipping tests"
  exit 0  # 返回成功
fi
```

✅ **正确**：
```
if ! webui_accessible; then
  echo "✗ WebUI not accessible - TEST FAILED"
  echo "  Fix: Deploy WebUI first"
  echo "  Command: cd webui && docker compose up -d"
  exit 1  # 返回失败
fi
```

#### 错误模式 3：部分验证

❌ **错误**：
```
# 只验证 K8s 集群
if kubectl get cluster "$name"; then
  echo "✓ Test passed"
fi
```

✅ **正确**：
```
# 验证所有5层资源
verify_k8s_cluster "$name" || exit 1
verify_database_record "$name" || exit 1
verify_argocd_registration "$name" || exit 1
verify_git_branch "$name" || exit 1
verify_portainer_endpoint "$name" || exit 1
echo "✓ Test passed (all 5 layers verified)"
```

---

## 实战检查清单

### 声称"测试通过"前必须确认

- [ ] 测试从 `clean.sh --all` 开始
- [ ] 测试自动执行 `bootstrap.sh`
- [ ] 测试无需任何手动命令
- [ ] 测试失败会立即停止
- [ ] 测试结果自动验证
- [ ] 测试可以重复执行
- [ ] 测试后无孤立资源（除预期保留的）
- [ ] 文档中提供独立验证命令
- [ ] 至少3轮测试结果一致

### 代码审查检查项

- [ ] 有 `clean.sh --all` 调用
- [ ] 有 `bootstrap.sh` 调用
- [ ] 有初始状态验证
- [ ] 有最终状态验证
- [ ] 有 fail-fast 机制（`set -e` 或显式检查）
- [ ] E2E 测试有防御性清理
- [ ] 有 trap 机制
- [ ] 无手动清理提示
- [ ] 无手动验证提示

### 文档审查检查项

- [ ] 验收标准明确
- [ ] 提供一键运行命令
- [ ] 说明预期结果
- [ ] 说明保留/删除的资源
- [ ] 无"请手动..."字样
- [ ] 提供自动验证命令

---

## 附录：验证命令

### 验证测试幂等性

```bash
# 从脏环境开始（假设有孤立资源）
# 直接运行测试，应该自动清理并通过
tests/run_tests.sh all

# 重复3次，结果应该一致
for i in 1 2 3; do
  echo "=== Round $i ==="
  tests/run_tests.sh all
done
```

### 验证资源状态

```bash
# 预置集群（应该存在）
k3d cluster list | grep -E "devops|dev|uat|prod"

# 测试集群（应该有2个保留）
k3d cluster list | grep "test-api-"
kind get clusters | grep "test-api-"

# 孤立资源（应该为0）
kubectl --context k3d-devops get secrets -n argocd \
  -l "argocd.argoproj.io/secret-type=cluster" \
  --no-headers | grep "test-e2e-" | wc -l
```

### 验证文档一致性

  ```bash
# 检查三个规则文件都包含相关内容
grep -l "零.*手动\|Zero.*Manual\|manual.*intervention" \
  .cursorrules AGENTS.md CLAUDE.md
```

---

## 参考文档

- `.cursorrules` - 项目通用规则
- `AGENTS.md` - 详细指南和历史案例
- `tests/run_tests.sh` - 测试套件入口
- `tests/webui_api_test.sh` - WebUI E2E 测试示例

---

**最后提醒**：当你准备说"测试通过"时，先问自己：

1. 用户需要运行任何手动命令吗？ → 如果是，**测试失败**
2. 我在测试前手动清理了吗？ → 如果是，**测试失败**
3. 测试跳过了某些检查吗？ → 如果是，**测试失败**
4. 测试能从零状态开始并通过吗？ → 如果否，**测试失败**

**只有4个答案都正确，才能说"测试通过"。**
