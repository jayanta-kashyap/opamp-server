#!/bin/bash

# Stop Port-Forward
# Usage: ./scripts/stop-port-forward.sh

PID_FILE="/tmp/opamp-port-forward.pid"

echo "🛑 Stopping OpAMP port-forward..."

# Kill the wrapper script via PID file
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping wrapper (PID: $PID)..."
        kill "$PID" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# Kill any remaining processes
lsof -ti:4321 | xargs kill -9 2>/dev/null || true
pkill -f "opamp-port-forward-wrapper" 2>/dev/null || true
pkill -f "port-forward.*opamp-server.*4321" 2>/dev/null || true

# Cleanup
rm -f /tmp/opamp-port-forward-wrapper.sh 2>/dev/null

echo "✅ Port-forward stopped"
