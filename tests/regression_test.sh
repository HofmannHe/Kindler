#!/usr/bin/env bash
# 完整回归测试
# 端到端测试：清理 → 引导 → 创建集群 → 验证

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 [--skip-clean] [--skip-bootstrap] [--clusters CLUSTER1,CLUSTER2,...]

Options:
  --skip-clean      Skip environment cleanup
  --skip-bootstrap  Skip bootstrap process
  --clusters LIST   Comma-separated list of clusters to create (default: all from CSV)

Examples:
  $0                                    # Full regression test
  $0 --skip-clean                       # Keep existing environment
  $0 --clusters dev-k3d,prod-k3d        # Test specific clusters only
EOF
  exit 1
}

# 解析参数
SKIP_CLEAN=0
SKIP_BOOTSTRAP=0
CLUSTER_LIST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-clean)
      SKIP_CLEAN=1
      shift
      ;;
    --skip-bootstrap)
      SKIP_BOOTSTRAP=1
      shift
      ;;
    --clusters)
      CLUSTER_LIST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

echo "=========================================="
echo "  Full Regression Test"
echo "=========================================="
echo "Started: $(date)"
echo ""

overall_start=$(date +%s)
step_num=1
total_steps=4

# 1. Clean environment
if [ $SKIP_CLEAN -eq 0 ]; then
  echo "[$step_num/$total_steps] Cleaning environment..."
  step_start=$(date +%s)
  
  if bash "$ROOT_DIR/scripts/clean.sh" --all; then
    step_end=$(date +%s)
    echo "✓ Clean completed in $((step_end - step_start))s"
  else
    echo "✗ Clean failed"
    exit 1
  fi
else
  echo "[$step_num/$total_steps] Skipping clean (--skip-clean)"
fi
step_num=$((step_num + 1))

# 2. Bootstrap
if [ $SKIP_BOOTSTRAP -eq 0 ]; then
  echo ""
  echo "[$step_num/$total_steps] Running bootstrap..."
  step_start=$(date +%s)
  
  if bash "$ROOT_DIR/scripts/bootstrap.sh"; then
    step_end=$(date +%s)
    echo "✓ Bootstrap completed in $((step_end - step_start))s"
  else
    echo "✗ Bootstrap failed"
    exit 1
  fi
else
  echo "[$step_num/$total_steps] Skipping bootstrap (--skip-bootstrap)"
fi
step_num=$((step_num + 1))

# 3. Create business clusters
echo ""
echo "[$step_num/$total_steps] Creating business clusters..."
step_start=$(date +%s)

if [ -n "$CLUSTER_LIST" ]; then
  clusters=$(echo "$CLUSTER_LIST" | tr ',' ' ')
else
  clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv")
fi

cluster_count=0
failed_clusters=""

for cluster in $clusters; do
  cluster_count=$((cluster_count + 1))
  echo "  [$cluster_count] Creating $cluster..."
  
  if bash "$ROOT_DIR/scripts/create_env.sh" -n "$cluster"; then
    echo "    ✓ $cluster created"
  else
    echo "    ✗ $cluster creation failed"
    failed_clusters="$failed_clusters $cluster"
  fi
done

step_end=$(date +%s)

if [ -z "$failed_clusters" ]; then
  echo "✓ All clusters created in $((step_end - step_start))s"
else
  echo "✗ Some clusters failed:$failed_clusters"
  exit 1
fi
step_num=$((step_num + 1))

# 4. Run test suite
echo ""
echo "[$step_num/$total_steps] Running test suite..."
step_start=$(date +%s)

if bash "$ROOT_DIR/tests/run_tests.sh" all; then
  step_end=$(date +%s)
  echo "✓ Test suite passed in $((step_end - step_start))s"
else
  step_end=$(date +%s)
  echo "✗ Test suite failed in $((step_end - step_start))s"
  exit 1
fi

overall_end=$(date +%s)
overall_duration=$((overall_end - overall_start))

echo ""
echo "=========================================="
echo "  Regression Test Complete"
echo "=========================================="
echo "Completed: $(date)"
echo "Total duration: ${overall_duration}s ($((overall_duration / 60))m $((overall_duration % 60))s)"
echo "Status: ✓ ALL STEPS PASSED"

exit 0

