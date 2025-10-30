#!/usr/bin/env bash
# 持续监控测试进度

LOG_FILE="/tmp/test_final_fixed.log"

echo "Monitoring test progress (Ctrl+C to stop monitoring, test continues)..."
echo "Log file: $LOG_FILE"
echo ""

last_iteration=0
last_step=""

while true; do
  # 检查测试进程是否还在运行
  if ! pgrep -f "test_full_cycle.sh.*--iterations 3" > /dev/null 2>&1; then
    echo ""
    echo "========================================="
    echo "Test process finished!"
    echo "========================================="
    echo ""
    tail -40 "$LOG_FILE"
    break
  fi
  
  # 提取当前进度
  current_iteration=$(grep -oP "Starting iteration \K\d+" "$LOG_FILE" | tail -1 || echo "0")
  current_step=$(grep -oP "Step \K\d+:" "$LOG_FILE" | tail -1 || echo "")
  
  # 只在状态变化时输出
  if [ "$current_iteration" != "$last_iteration" ] || [ "$current_step" != "$last_step" ]; then
    clear
    echo "========================================="
    echo "Test Progress Monitor"
    echo "========================================="
    echo "Current Time: $(date '+%H:%M:%S')"
    echo "Iteration: $current_iteration/3"
    echo "Last Step: $current_step"
    echo ""
    echo "Recent logs:"
    tail -15 "$LOG_FILE" | grep -E "Step|iteration|✓|✗|Creating|Verifying" || tail -10 "$LOG_FILE"
    echo ""
    echo "Press Ctrl+C to stop monitoring (test will continue)"
    
    last_iteration=$current_iteration
    last_step=$current_step
  fi
  
  sleep 10
done

