#!/bin/bash

# Stop Port-Forward
# Usage: ./scripts/stop-port-forward.sh

PID_FILE="/tmp/opamp-port-forward.pid"
LOG_FILE="/tmp/opamp-port-forward.log"

if [ -f "$PID_FILE" ]; then
    PF_PID=$(cat "$PID_FILE")
    if kill -0 "$PF_PID" 2>/dev/null; then
        echo "Stopping port-forward (PID: $PF_PID)..."
        kill "$PF_PID" 2>/dev/null
        echo "✅ Port-forward stopped"
    else
        echo "⚠️  Port-forward not running"
    fi
    rm -f "$PID_FILE"
else
    echo "⚠️  No PID file found"
fi

# Cleanup any remaining processes on port 8080
lsof -ti:8080 | xargs kill -9 2>/dev/null || true

# Clean log file
rm -f "$LOG_FILE"

echo "🧹 Cleanup complete"
