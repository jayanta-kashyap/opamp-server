#!/bin/bash

# Start Port-Forward - Keeps running in background
# Usage: ./scripts/start-port-forward.sh

PID_FILE="/tmp/opamp-port-forward.pid"
LOG_FILE="/tmp/opamp-port-forward.log"

# Kill existing port-forward
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Stopping existing port-forward (PID: $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null
        sleep 2
    fi
    rm -f "$PID_FILE"
fi

# Kill any process on port 8080
lsof -ti:8080 | xargs kill -9 2>/dev/null || true

echo "Starting port-forward (8080:4321)..."

# Start port-forward in background with nohup
nohup kubectl --context control-plane port-forward -n opamp-control svc/opamp-server 8080:4321 > "$LOG_FILE" 2>&1 &
PF_PID=$!

# Save PID
echo $PF_PID > "$PID_FILE"

sleep 2

# Verify it's running
if kill -0 $PF_PID 2>/dev/null; then
    echo "✅ Port-forward started successfully (PID: $PF_PID)"
    echo "📊 UI available at: http://localhost:8080"
    echo "📝 Logs: tail -f $LOG_FILE"
    echo "🛑 To stop: ./scripts/stop-port-forward.sh"
else
    echo "❌ Failed to start port-forward"
    cat "$LOG_FILE"
    exit 1
fi
