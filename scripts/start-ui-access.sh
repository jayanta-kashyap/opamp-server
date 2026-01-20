#!/bin/bash
# Automated UI access - runs in background persistently with auto-restart

echo "🚀 Starting OpAMP UI access..."

# Kill any existing port-forward on port 4321
lsof -ti:4321 | xargs kill -9 2>/dev/null
pkill -f "port-forward.*opamp-server.*4321" 2>/dev/null

# Create a wrapper script that auto-restarts port-forward if it dies
cat > /tmp/opamp-port-forward-wrapper.sh << 'EOF'
#!/bin/bash
while true; do
    echo "[$(date)] Starting port-forward..."
    kubectl port-forward -n opamp-control svc/opamp-server 4321:4321 2>&1
    echo "[$(date)] Port-forward died, restarting in 2 seconds..."
    sleep 2
done
EOF
chmod +x /tmp/opamp-port-forward-wrapper.sh

# Start the wrapper in background
nohup /tmp/opamp-port-forward-wrapper.sh > /tmp/opamp-ui-forward.log 2>&1 &
PID=$!
echo $PID > /tmp/opamp-ui-forward.pid

sleep 3

# Verify it's working
if curl -s http://localhost:4321/api/devices > /dev/null 2>&1; then
    echo ""
    echo "✅ OpAMP UI is now accessible at: http://localhost:4321"
    echo ""
    echo "Background process PID: $PID (auto-restarts if connection drops)"
    echo "To stop: ./scripts/stop-ui-access.sh"
    echo ""
    # Open in browser automatically
    open http://localhost:4321 2>/dev/null || echo "Open http://localhost:4321 in your browser"
else
    echo "⚠️  Port-forward started but API not responding yet. Check /tmp/opamp-ui-forward.log"
fi
