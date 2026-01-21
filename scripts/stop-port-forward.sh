#!/bin/bash

# Stop Port-Forward
# Usage: ./scripts/stop-port-forward.sh

PID_FILE="/tmp/opamp-port-forward.pid"
PID_FILE_PROVISIONER="/tmp/opamp-provisioner-port-forward.pid"

echo "🛑 Stopping OpAMP port-forwards..."

# Kill the wrapper scripts via PID files
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping opamp-server wrapper (PID: $PID)..."
        kill "$PID" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

if [ -f "$PID_FILE_PROVISIONER" ]; then
    PID=$(cat "$PID_FILE_PROVISIONER")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping poc-provisioner wrapper (PID: $PID)..."
        kill "$PID" 2>/dev/null
    fi
    rm -f "$PID_FILE_PROVISIONER"
fi

# Kill any remaining processes
lsof -ti:4321 | xargs kill -9 2>/dev/null || true
lsof -ti:8090 | xargs kill -9 2>/dev/null || true
pkill -f "opamp-port-forward-wrapper" 2>/dev/null || true
pkill -f "opamp-provisioner-port-forward-wrapper" 2>/dev/null || true
pkill -f "port-forward.*opamp-server.*4321" 2>/dev/null || true
pkill -f "port-forward.*poc-provisioner.*8090" 2>/dev/null || true

# Cleanup
rm -f /tmp/opamp-port-forward-wrapper.sh 2>/dev/null
rm -f /tmp/opamp-provisioner-port-forward-wrapper.sh 2>/dev/null

echo "✅ Port-forwards stopped"
