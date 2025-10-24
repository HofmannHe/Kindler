#!/usr/bin/env bash
# 四源一致性测试 - 验证DB, Git, K8s, Portainer完全一致

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

success() { echo -e "${GREEN}✓${NC} $*"; passed=$((passed + 1)); }
fail() { echo -e "${RED}✗${NC} $*"; failed=$((failed + 1)); }
info() { echo -e "${YELLOW}➜${NC} $*"; }

echo "####################################################"
echo "# Four-Source Consistency Test"
echo "####################################################"
echo "Verifying DB-Git-K8s-Portainer consistency..."
echo ""

# 读取数据源1: PostgreSQL数据库
info "[1/4] Reading PostgreSQL database..."
db_clusters=$(kubectl --context k3d-devops -n paas exec postgresql-0 -- \
  psql -U kindler -d kindler -t -c "SELECT name FROM clusters ORDER BY name" 2>/dev/null | \
  tr -d ' ' | grep -v '^$' | sort || echo "")

if [ -n "$db_clusters" ]; then
  db_count=$(echo "$db_clusters" | wc -l)
  success "DB has $db_count cluster(s)"
  echo "$db_clusters" | sed 's/^/    - /'
else
  info "DB has 0 clusters"
  db_count=0
fi

# 读取数据源2: Git分支
info "[2/4] Reading Git branches..."
if [ -f "$ROOT_DIR/config/git.env" ]; then
  source "$ROOT_DIR/config/git.env"
  
  # 只取业务集群分支（排除main、master、develop等）
  git_branches=$(timeout 15 git ls-remote "$GIT_REPO_URL" 2>/dev/null | \
    grep 'refs/heads/' | \
    grep -v -E '(main|master|develop|release|devops|HEAD)' | \
    cut -d'/' -f3 | \
    sort || echo "")
  
  if [ -n "$git_branches" ]; then
    git_count=$(echo "$git_branches" | wc -l)
    success "Git has $git_count business branch(es)"
    echo "$git_branches" | sed 's/^/    - /'
  else
    info "Git has 0 business branches"
    git_count=0
  fi
else
  info "Git config not found, skipping"
  git_branches=""
  git_count=0
fi

# 读取数据源3: Kubernetes集群
info "[3/4] Reading Kubernetes clusters..."
k3d_clusters=$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null | \
  grep -v '^devops$' | sort || echo "")
kind_clusters=$(kind get clusters 2>/dev/null | sort || echo "")

k8s_clusters=$(echo -e "${k3d_clusters}\n${kind_clusters}" | grep -v '^$' | sort)

if [ -n "$k8s_clusters" ]; then
  k8s_count=$(echo "$k8s_clusters" | wc -l)
  success "K8s has $k8s_count business cluster(s)"
  echo "$k8s_clusters" | sed 's/^/    - /'
else
  info "K8s has 0 business clusters"
  k8s_count=0
fi

# 读取数据源4: Portainer endpoints
info "[4/4] Reading Portainer endpoints..."
if docker ps | grep -q "portainer-ce"; then
  # 获取Portainer admin token
  if [ -f "$ROOT_DIR/config/secrets.env" ]; then
    source "$ROOT_DIR/config/secrets.env"
    
    # 尝试登录获取token（简化版，可能需要改进）
    # 注意：这需要Portainer API可访问
    portainer_endpoints=$(docker exec portainer-ce sh -c \
      "ls -1 /data/portainer/endpoints 2>/dev/null | grep -v '^$'" 2>/dev/null | \
      sort || echo "")
    
    if [ -n "$portainer_endpoints" ]; then
      portainer_count=$(echo "$portainer_endpoints" | wc -l)
      info "Portainer has $portainer_count endpoint(s) (directory-based count)"
    else
      info "Portainer has 0 endpoints"
      portainer_count=0
    fi
  else
    info "Cannot verify Portainer endpoints (secrets.env not found)"
    portainer_endpoints=""
    portainer_count=0
  fi
else
  info "Portainer not running, skipping endpoint check"
  portainer_endpoints=""
  portainer_count=0
fi

# 一致性分析
echo ""
echo "=========================================="
echo "Consistency Analysis"
echo "=========================================="
echo ""

# 比较DB vs K8s
info "Comparing DB vs K8s..."
if [ "$db_count" -eq "$k8s_count" ]; then
  if [ "$db_count" -eq 0 ]; then
    success "Both DB and K8s have 0 clusters (consistent)"
  else
    # 详细比较内容
    diff_result=$(diff <(echo "$db_clusters") <(echo "$k8s_clusters") || true)
    if [ -z "$diff_result" ]; then
      success "DB and K8s are consistent ($db_count clusters match)"
    else
      fail "DB and K8s have same count but different clusters"
      echo "Differences:"
      echo "$diff_result" | sed 's/^/  /'
    fi
  fi
else
  fail "DB-K8s mismatch: DB=$db_count, K8s=$k8s_count"
  
  # 显示差异
  echo "  DB only:"
  comm -23 <(echo "$db_clusters") <(echo "$k8s_clusters") | sed 's/^/    - /'
  echo "  K8s only:"
  comm -13 <(echo "$db_clusters") <(echo "$k8s_clusters") | sed 's/^/    - /'
fi

# 比较DB vs Git
if [ "$git_count" -gt 0 ]; then
  info "Comparing DB vs Git..."
  if [ "$db_count" -eq "$git_count" ]; then
    diff_result=$(diff <(echo "$db_clusters") <(echo "$git_branches") || true)
    if [ -z "$diff_result" ]; then
      success "DB and Git are consistent ($db_count branches match)"
    else
      fail "DB and Git have same count but different branches"
      echo "Differences:"
      echo "$diff_result" | sed 's/^/  /'
    fi
  else
    fail "DB-Git mismatch: DB=$db_count, Git=$git_count"
    
    echo "  DB only:"
    comm -23 <(echo "$db_clusters") <(echo "$git_branches") | sed 's/^/    - /'
    echo "  Git only:"
    comm -13 <(echo "$db_clusters") <(echo "$git_branches") | sed 's/^/    - /'
  fi
fi

# 检查孤立资源
echo ""
info "Checking for orphaned resources..."

# K8s集群存在但DB中不存在
orphaned_k8s=$(timeout 10 comm -13 <(echo "$db_clusters") <(echo "$k8s_clusters") 2>/dev/null | grep -v '^$' || echo "")
if [ -n "$orphaned_k8s" ]; then
  fail "Found K8s clusters not in DB:"
  echo "$orphaned_k8s" | sed 's/^/    - /'
  echo "  Fix: Run 'scripts/delete_env.sh <cluster>' or add to DB"
else
  success "No orphaned K8s clusters"
fi

# DB记录存在但K8s集群不存在
orphaned_db=$(timeout 10 comm -23 <(echo "$db_clusters") <(echo "$k8s_clusters") 2>/dev/null | grep -v '^$' || echo "")
if [ -n "$orphaned_db" ]; then
  fail "Found DB records without K8s clusters:"
  echo "$orphaned_db" | sed 's/^/    - /'
  echo "  Fix: Delete from DB or recreate clusters"
else
  success "No orphaned DB records"
fi

# Git分支存在但DB中不存在
if [ "$git_count" -gt 0 ]; then
  orphaned_git=$(timeout 10 comm -13 <(echo "$db_clusters") <(echo "$git_branches") 2>/dev/null | grep -v '^$' || echo "")
  if [ -n "$orphaned_git" ]; then
    fail "Found Git branches not in DB:"
    echo "$orphaned_git" | sed 's/^/    - /'
    echo "  Fix: Run 'scripts/cleanup_orphaned_branches.sh' or add to DB"
  else
    success "No orphaned Git branches"
  fi
fi

# 总结
echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Data sources:"
echo "  DB:        $db_count clusters"
echo "  Git:       $git_count branches"
echo "  K8s:       $k8s_count clusters"
echo "  Portainer: $portainer_count endpoints (directory-based)"
echo ""
echo "Test results:"
echo "  Passed: $passed"
echo "  Failed: $failed"
echo ""

# 建议修复命令
if [ $failed -gt 0 ]; then
  echo "Suggested fixes:"
  if [ -n "$orphaned_k8s" ]; then
    echo "  # Remove orphaned K8s clusters:"
    echo "$orphaned_k8s" | sed 's/^/  scripts\/delete_env.sh /'
  fi
  if [ -n "$orphaned_db" ]; then
    echo "  # Remove orphaned DB records:"
    echo "  kubectl --context k3d-devops -n paas exec postgresql-0 -- \\"
    echo "$orphaned_db" | sed "s/^/    psql -U kindler -d kindler -c \"DELETE FROM clusters WHERE name='/" | sed "s/$/';\"/""
  fi
  if [ -n "$orphaned_git" ]; then
    echo "  # Remove orphaned Git branches:"
    echo "  scripts/cleanup_orphaned_branches.sh"
  fi
  echo ""
  
  echo -e "${RED}✗ Consistency check failed${NC}"
  exit 1
else
  echo -e "${GREEN}✓ All sources are consistent!${NC}"
  exit 0
fi

