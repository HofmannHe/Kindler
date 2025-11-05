#!/usr/bin/env bash
# 监控测试进度

LOG_FILE="/tmp/test_output_final.log"
CHECK_INTERVAL=30  # 每30秒检查一次

echo "Monitoring test progress..."
echo "Log file: $LOG_FILE"
echo ""

last_lines=0
while true; do
  if ! ps -p $(pgrep -f "test_full_cycle.sh" | head -1) > /dev/null 2>&1; then
    echo ""
    echo "================================="
    echo "Test completed or stopped"
    echo "================================="
    echo ""
    echo "Final output:"
    tail -50 "$LOG_FILE"
    break
  fi
  
  # 显示新增的日志行
  current_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$current_lines" -gt "$last_lines" ]; then
    new_lines=$((current_lines - last_lines))
    tail -n "$new_lines" "$LOG_FILE" | grep -E "(\[.*\]|✓|✗|Step|iteration)" || true
    last_lines=$current_lines
  fi
  
  sleep "$CHECK_INTERVAL"
done

