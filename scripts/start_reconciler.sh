#!/usr/bin/env bash
# 启动 Reconciler 作为后台服务

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PID_FILE="/tmp/kindler_reconciler.pid"
LOG_FILE="/tmp/kindler_reconciler.log"

# 读取可选配置（如 BASE_DOMAIN, RECONCILER_CONCURRENCY 等）
if [ -f "$ROOT_DIR/config/clusters.env" ]; then
  . "$ROOT_DIR/config/clusters.env"
fi
RECONCILER_CONCURRENCY="${RECONCILER_CONCURRENCY:-3}"

case "${1:-start}" in
  start)
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
      echo "Reconciler already running (PID: $(cat $PID_FILE))"
      exit 0
    fi
    
    echo "Starting Kindler Reconciler..."
    echo "  Concurrency: RECONCILER_CONCURRENCY=$RECONCILER_CONCURRENCY"
    nohup env RECONCILER_CONCURRENCY="$RECONCILER_CONCURRENCY" \
      "$ROOT_DIR/scripts/reconciler.sh" loop >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "✓ Reconciler started (PID: $(cat $PID_FILE))"
    echo "  Log file: $LOG_FILE"
    echo "  Reconcile interval: 30s"
    ;;
    
  stop)
    if [ ! -f "$PID_FILE" ]; then
      echo "Reconciler not running"
      exit 0
    fi
    
    PID=$(cat "$PID_FILE")
    echo "Stopping Reconciler (PID: $PID)..."
    kill "$PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "✓ Reconciler stopped"
    ;;
    
  status)
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
      echo "✓ Reconciler running (PID: $(cat $PID_FILE))"
      echo "  Log file: $LOG_FILE"
      echo "  Concurrency: RECONCILER_CONCURRENCY=$RECONCILER_CONCURRENCY"
      echo "  Last 10 lines:"
      tail -10 "$LOG_FILE" | sed 's/^/    /'
    else
      echo "✗ Reconciler not running"
      [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
    fi
    ;;
    
  logs)
    tail -f "$LOG_FILE"
    ;;
    
  *)
    echo "Usage: $0 {start|stop|status|logs}"
    exit 1
    ;;
esac
