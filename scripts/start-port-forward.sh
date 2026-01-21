#!/bin/bash

# Start Port-Forward - Keeps running in background with auto-restart
# Usage: ./scripts/start-port-forward.sh
# Forwards:
#   - OpAMP Server: localhost:4321 (Dashboard UI)
#   - POC Provisioner: localhost:8090 (Device deploy/remove API)

PID_FILE="/tmp/opamp-port-forward.pid"
PID_FILE_PROVISIONER="/tmp/opamp-provisioner-port-forward.pid"
LOG_FILE="/tmp/opamp-port-forward.log"
LOG_FILE_PROVISIONER="/tmp/opamp-provisioner-port-forward.log"
WRAPPER_SCRIPT="/tmp/opamp-port-forward-wrapper.sh"
WRAPPER_SCRIPT_PROVISIONER="/tmp/opamp-provisioner-port-forward-wrapper.sh"

echo "🚀 Starting OpAMP port-forwards..."

# Kill existing processes
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Stopping existing port-forward (PID: $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

if [ -f "$PID_FILE_PROVISIONER" ]; then
    OLD_PID=$(cat "$PID_FILE_PROVISIONER")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Stopping existing provisioner port-forward (PID: $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null
        sleep 1
    fi
    rm -f "$PID_FILE_PROVISIONER"
fi

# Kill any process on ports 4321 and 8090
lsof -ti:4321 | xargs kill -9 2>/dev/null || true
lsof -ti:8090 | xargs kill -9 2>/dev/null || true
pkill -f "opamp-port-forward-wrapper" 2>/dev/null || true
pkill -f "opamp-provisioner-port-forward-wrapper" 2>/dev/null || true
pkill -f "port-forward.*opamp-server.*4321" 2>/dev/null || true
pkill -f "port-forward.*poc-provisioner.*8090" 2>/dev/null || true

# Create wrapper script for OpAMP Server (4321)
cat > "$WRAPPER_SCRIPT" << 'INNER_EOF'
#!/bin/bash
while true; do
    echo "[$(date)] Starting opamp-server port-forward..."
    kubectl port-forward -n opamp-control svc/opamp-server 4321:4321 2>&1
    echo "[$(date)] Port-forward died, restarting in 2 seconds..."
    sleep 2
done
INNER_EOF
chmod +x "$WRAPPER_SCRIPT"

# Create wrapper script for POC Provisioner (8090)
cat > "$WRAPPER_SCRIPT_PROVISIONER" << 'INNER_EOF'
#!/bin/bash
while true; do
    echo "[$(date)] Starting poc-provisioner port-forward..."
    kubectl port-forward -n opamp-control svc/poc-provisioner 8090:8090 2>&1
    echo "[$(date)] Port-forward died, restarting in 2 seconds..."
    sleep 2
done
INNER_EOF
chmod +x "$WRAPPER_SCRIPT_PROVISIONER"

echo "Starting port-forwards with auto-restart..."

# Start wrappers in background with nohup
nohup "$WRAPPER_SCRIPT" > "$LOG_FILE" 2>&1 &
PF_PID=$!
echo $PF_PID > "$PID_FILE"

nohup "$WRAPPER_SCRIPT_PROVISIONER" > "$LOG_FILE_PROVISIONER" 2>&1 &
PF_PID_PROVISIONER=$!
echo $PF_PID_PROVISIONER > "$PID_FILE_PROVISIONER"

sleep 3

# Verify it's working
if curl -s http://localhost:4321/api/devices > /dev/null 2>&1; then
    echo ""
    echo "✅ Port-forwards started successfully"
    echo "   OpAMP Server:    http://localhost:4321 (PID: $PF_PID)"
    echo "   POC Provisioner: http://localhost:8090 (PID: $PF_PID_PROVISIONER)"
    echo ""
    echo "📊 Dashboard UI: http://localhost:4321"
    echo "📝 Logs: tail -f $LOG_FILE"
    echo "🛑 To stop: ./scripts/stop-port-forward.sh"
    echo ""
    echo "ℹ️  Port-forwards will auto-restart if connection drops"
else
    echo ""
    echo "⚠️  Port-forwards started but API not responding yet."
    echo "    Check logs: tail -f $LOG_FILE"
    echo "    OpAMP Server PID: $PF_PID"
    echo "    POC Provisioner PID: $PF_PID_PROVISIONER"
fi
