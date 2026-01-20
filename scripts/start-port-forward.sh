#!/bin/bash

# Start Port-Forward - Keeps running in background with auto-restart
# Usage: ./scripts/start-port-forward.sh

PID_FILE="/tmp/opamp-port-forward.pid"
LOG_FILE="/tmp/opamp-port-forward.log"
WRAPPER_SCRIPT="/tmp/opamp-port-forward-wrapper.sh"

echo "🚀 Starting OpAMP port-forward..."

# Kill existing processes
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Stopping existing port-forward (PID: $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null
        sleep 2
    fi
    rm -f "$PID_FILE"
fi

# Kill any process on port 4321
lsof -ti:4321 | xargs kill -9 2>/dev/null || true
pkill -f "opamp-port-forward-wrapper" 2>/dev/null || true
pkill -f "port-forward.*opamp-server.*4321" 2>/dev/null || true

# Create a wrapper script that auto-restarts port-forward if it dies
cat > "$WRAPPER_SCRIPT" << 'INNER_EOF'
#!/bin/bash
while true; do
    echo "[$(date)] Starting port-forward..."
    kubectl port-forward -n opamp-control svc/opamp-server 4321:4321 2>&1
    echo "[$(date)] Port-forward died, restarting in 2 seconds..."
    sleep 2
done
INNER_EOF
chmod +x "$WRAPPER_SCRIPT"

echo "Starting port-forward with auto-restart (4321:4321)..."

# Start wrapper in background with nohup
nohup "$WRAPPER_SCRIPT" > "$LOG_FILE" 2>&1 &
PF_PID=$!

# Save PID
echo $PF_PID > "$PID_FILE"

sleep 3

# Verify it's working
if curl -s http://localhost:4321/api/devices > /dev/null 2>&1; then
    echo ""
    echo "✅ Port-forward started successfully (PID: $PF_PID)"
    echo "📊 UI available at: http://localhost:4321"
    echo "📝 Logs: tail -f $LOG_FILE"
    echo "🛑 To stop: ./scripts/stop-port-forward.sh"
    echo ""
    echo "ℹ️  Port-forward will auto-restart if connection drops"
else
    echo ""
    echo "⚠️  Port-forward started but API not responding yet."
    echo "    Check logs: tail -f $LOG_FILE"
    echo "    PID: $PF_PID"
fi
