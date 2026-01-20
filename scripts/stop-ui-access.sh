#!/bin/bash
# Stop the UI access port-forward

echo "🛑 Stopping OpAMP UI access..."

# Kill the wrapper script
if [ -f /tmp/opamp-ui-forward.pid ]; then
    PID=$(cat /tmp/opamp-ui-forward.pid)
    echo "Stopping wrapper with PID: $PID"
    kill $PID 2>/dev/null
    rm /tmp/opamp-ui-forward.pid
fi

# Kill any port-forward processes on 4321
lsof -ti:4321 | xargs kill -9 2>/dev/null

# Kill any wrapper script still running
pkill -f "opamp-port-forward-wrapper" 2>/dev/null
pkill -f "port-forward.*opamp-server.*4321" 2>/dev/null

# Cleanup temp files
rm -f /tmp/opamp-port-forward-wrapper.sh 2>/dev/null

echo "✅ UI access stopped"
