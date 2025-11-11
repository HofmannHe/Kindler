#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
  cat >&2 <<USAGE
Usage: $0 [options]

自动化完整流程测试：清理 → bootstrap → 创建业务集群 → 验证

选项:
  --rounds N        运行 N 轮测试（默认: 1）
  --clean-all       每轮测试前完全清理（包括 devops）
  --skip-bootstrap  跳过 bootstrap（假设 devops 已就绪）
  --clusters LIST   指定要创建的集群（逗号分隔），默认从 CSV 读取所有业务集群
  --output FILE     保存测试结果到文件（默认: data/test_results.txt）
  --timeout SECONDS bootstrap 超时时间（默认: 900秒）
USAGE
  exit 1
}

# Parse arguments
rounds=1
clean_all=0
skip_bootstrap=0
clusters=""
output_file="$ROOT_DIR/data/test_results.txt"
timeout=900

while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) rounds="$2"; shift 2 ;;
    --rounds=*) rounds="${1#--rounds=}"; shift ;;
    --clean-all) clean_all=1; shift ;;
    --skip-bootstrap) skip_bootstrap=1; shift ;;
    --clusters) clusters="$2"; shift 2 ;;
    --clusters=*) clusters="${1#--clusters=}"; shift ;;
    --output) output_file="$2"; shift 2 ;;
    --output=*) output_file="${1#--output=}"; shift ;;
    --timeout) timeout="$2"; shift 2 ;;
    --timeout=*) timeout="${1#--timeout=}"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Ensure output directory exists
mkdir -p "$(dirname "$output_file")"

# Get clusters list
if [ -z "$clusters" ]; then
  # Read from CSV (excluding devops and comments)
  if [ -f "$ROOT_DIR/config/environments.csv" ]; then
    clusters=$(awk -F, '$0 !~ /^[[:space:]]*#/ && NF>0 && $1!="devops" {print $1}' "$ROOT_DIR/config/environments.csv" | tr '\n' ',' | sed 's/,$//')
  else
    echo "[ERROR] No clusters.csv found and no --clusters specified" >&2
    exit 1
  fi
fi

echo "==================================================================="
echo "  Kindler Full Integration Test"
echo "==================================================================="
echo "Rounds:    $rounds"
echo "Clean all: $clean_all"
echo "Skip bootstrap: $skip_bootstrap"
echo "Clusters:  $clusters"
echo "Output:    $output_file"
echo "Timeout:   ${timeout}s"
echo "==================================================================="
echo ""

# Initialize results file
{
  echo "======================================================================"
  echo "Kindler Integration Test Results"
  echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "======================================================================"
  echo ""
} > "$output_file"

total_errors=0
total_warnings=0

for round in $(seq 1 "$rounds"); do
  echo ""
  echo "###################################################################"
  echo "# Round $round/$rounds"
  echo "###################################################################"
  echo ""
  
  round_start=$(date +%s)
  round_errors=0
  round_warnings=0
  
  # Record round start
  {
    echo "----------------------------------------------------------------------"
    echo "Round $round/$rounds - Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "----------------------------------------------------------------------"
  } >> "$output_file"
  
  # Step 1: Clean
  echo "[Round $round] Step 1/4: Cleaning environment..."
  clean_start=$(date +%s)
  if [ "$clean_all" -eq 1 ]; then
    if timeout 120 "$ROOT_DIR/scripts/clean.sh" --all 2>&1 | tee -a "$output_file"; then
      clean_time=$(($(date +%s) - clean_start))
      echo "[Round $round] ✓ Clean completed in ${clean_time}s"
      echo "Clean: PASS (${clean_time}s)" >> "$output_file"
    else
      echo "[Round $round] ✗ Clean failed"
      echo "Clean: FAIL" >> "$output_file"
      round_errors=$((round_errors+1))
      continue
    fi
  else
    if timeout 120 "$ROOT_DIR/scripts/clean.sh" 2>&1 | tee -a "$output_file"; then
      clean_time=$(($(date +%s) - clean_start))
      echo "[Round $round] ✓ Clean completed in ${clean_time}s"
      echo "Clean: PASS (${clean_time}s)" >> "$output_file"
    else
      echo "[Round $round] ✗ Clean failed"
      echo "Clean: FAIL" >> "$output_file"
      round_errors=$((round_errors+1))
      continue
    fi
  fi
  
  # Step 2: Bootstrap (if not skipped)
  if [ "$skip_bootstrap" -eq 0 ]; then
    echo "[Round $round] Step 2/4: Running bootstrap..."
    bootstrap_start=$(date +%s)
    if timeout "$timeout" "$ROOT_DIR/scripts/bootstrap.sh" 2>&1 | tee -a "$output_file"; then
      bootstrap_time=$(($(date +%s) - bootstrap_start))
      echo "[Round $round] ✓ Bootstrap completed in ${bootstrap_time}s"
      echo "Bootstrap: PASS (${bootstrap_time}s)" >> "$output_file"
    else
      echo "[Round $round] ✗ Bootstrap failed or timed out"
      echo "Bootstrap: FAIL" >> "$output_file"
      round_errors=$((round_errors+1))
      continue
    fi
  else
    echo "[Round $round] Step 2/4: Skipping bootstrap"
    echo "Bootstrap: SKIPPED" >> "$output_file"
  fi
  
  # Step 3: Create business clusters
  echo "[Round $round] Step 3/4: Creating business clusters..."
  create_start=$(date +%s)
  cluster_errors=0
  
  IFS=',' read -ra CLUSTER_ARRAY <<< "$clusters"
  for cluster in "${CLUSTER_ARRAY[@]}"; do
    cluster=$(echo "$cluster" | xargs) # trim whitespace
    [ -z "$cluster" ] && continue
    
    echo "[Round $round] Creating cluster: $cluster"
    if timeout 300 "$ROOT_DIR/scripts/create_env.sh" -n "$cluster" 2>&1 | tee -a "$output_file"; then
      echo "[Round $round] ✓ Cluster $cluster created"
      echo "  $cluster: PASS" >> "$output_file"
    else
      echo "[Round $round] ✗ Cluster $cluster failed"
      echo "  $cluster: FAIL" >> "$output_file"
      cluster_errors=$((cluster_errors+1))
    fi
  done
  
  create_time=$(($(date +%s) - create_start))
  if [ "$cluster_errors" -eq 0 ]; then
    echo "[Round $round] ✓ All clusters created in ${create_time}s"
    echo "Create clusters: PASS (${create_time}s, ${#CLUSTER_ARRAY[@]} clusters)" >> "$output_file"
  else
    echo "[Round $round] ⚠ Some clusters failed ($cluster_errors/${#CLUSTER_ARRAY[@]})"
    echo "Create clusters: PARTIAL ($cluster_errors failures)" >> "$output_file"
    round_warnings=$((round_warnings+1))
  fi
  
  # Step 4: Verify clusters
  echo "[Round $round] Step 4/4: Verifying clusters..."
  verify_start=$(date +%s)
  verify_errors=0
  
  # Verify devops if not skipped
  if [ "$skip_bootstrap" -eq 0 ]; then
    echo "[Round $round] Verifying devops cluster..."
    if "$ROOT_DIR/scripts/verify_cluster.sh" devops --provider k3d --skip-network 2>&1 | tee -a "$output_file"; then
      echo "[Round $round] ✓ devops verified"
      echo "  devops: PASS" >> "$output_file"
    else
      echo "[Round $round] ⚠ devops verification failed"
      echo "  devops: WARN" >> "$output_file"
      verify_errors=$((verify_errors+1))
    fi
  fi
  
  # Verify business clusters
  for cluster in "${CLUSTER_ARRAY[@]}"; do
    cluster=$(echo "$cluster" | xargs)
    [ -z "$cluster" ] && continue
    
    echo "[Round $round] Verifying cluster: $cluster"
    if "$ROOT_DIR/scripts/verify_cluster.sh" "$cluster" 2>&1 | tee -a "$output_file"; then
      echo "[Round $round] ✓ $cluster verified"
      echo "  $cluster: PASS" >> "$output_file"
    else
      echo "[Round $round] ⚠ $cluster verification failed"
      echo "  $cluster: WARN" >> "$output_file"
      verify_errors=$((verify_errors+1))
    fi
  done
  
  verify_time=$(($(date +%s) - verify_start))
  if [ "$verify_errors" -eq 0 ]; then
    echo "[Round $round] ✓ All verifications passed in ${verify_time}s"
    echo "Verification: PASS (${verify_time}s)" >> "$output_file"
  else
    echo "[Round $round] ⚠ Some verifications failed ($verify_errors)"
    echo "Verification: WARN ($verify_errors warnings)" >> "$output_file"
    round_warnings=$((round_warnings+1))
  fi
  
  # Round summary
  round_time=$(($(date +%s) - round_start))
  {
    echo ""
    echo "Round $round Summary:"
    echo "  Total time: ${round_time}s"
    echo "  Errors: $round_errors"
    echo "  Warnings: $round_warnings"
    if [ "$round_errors" -eq 0 ] && [ "$round_warnings" -eq 0 ]; then
      echo "  Status: ✓ PASS"
    elif [ "$round_errors" -eq 0 ]; then
      echo "  Status: ⚠ PASS (with warnings)"
    else
      echo "  Status: ✗ FAIL"
    fi
    echo ""
  } | tee -a "$output_file"
  
  total_errors=$((total_errors+round_errors))
  total_warnings=$((total_warnings+round_warnings))
done

# Final summary
echo ""
echo "==================================================================="
echo "  Test Complete"
echo "==================================================================="

# Determine exit status
if [ "$total_errors" -eq 0 ] && [ "$total_warnings" -eq 0 ]; then
  status_code=0
  status_text="✓ ALL PASS"
elif [ "$total_errors" -eq 0 ]; then
  status_code=0
  status_text="⚠ PASS (with warnings)"
else
  status_code=1
  status_text="✗ FAIL"
fi

{
  echo "======================================================================"
  echo "Final Summary"
  echo "Completed: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "======================================================================"
  echo "Rounds completed: $rounds"
  echo "Total errors: $total_errors"
  echo "Total warnings: $total_warnings"
  echo "Overall status: $status_text"
  echo "======================================================================"
} | tee -a "$output_file"

echo ""
echo "Full results saved to: $output_file"

exit $status_code

