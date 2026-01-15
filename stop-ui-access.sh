#!/bin/bash
# Stop the UI access port-forward

if [ -f /tmp/opamp-ui-forward.pid ]; then
    PID=$(cat /tmp/opamp-ui-forward.pid)
    echo "Stopping port-forward with PID: $PID"
    kill $PID 2>/dev/null
    rm /tmp/opamp-ui-forward.pid
    echo "✅ UI access stopped"
else
    echo "No PID file found"
    # Kill any port-forward on 4321 just in case
    lsof -ti:4321 | xargs kill -9 2>/dev/null && echo "Killed port-forward on 4321"
fi
