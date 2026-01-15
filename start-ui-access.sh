#!/bin/bash
# Automated UI access - runs in background persistently

echo "🚀 Starting OpAMP UI access..."

# Kill any existing port-forward on port 4321
lsof -ti:4321 | xargs kill -9 2>/dev/null

# Start port-forward in background
nohup kubectl port-forward -n opamp-system svc/opamp-server 4321:4321 > /tmp/opamp-ui-forward.log 2>&1 &
PID=$!
echo $PID > /tmp/opamp-ui-forward.pid

sleep 2

echo ""
echo "✅ OpAMP UI is now accessible at: http://localhost:4321"
echo ""
echo "Background process PID: $PID"
echo "To stop: ./stop-ui-access.sh"
echo ""

# Open in browser automatically
open http://localhost:4321 2>/dev/null || echo "Open http://localhost:4321 in your browser"
