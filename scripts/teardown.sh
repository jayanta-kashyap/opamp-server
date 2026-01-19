#!/bin/bash

# OpAMP POC - Complete Teardown Script
# Usage: ./scripts/teardown.sh
#
# This script removes all POC resources but keeps minikube running

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="control-plane"

echo "=============================================="
echo "  OpAMP POC - Teardown"
echo "=============================================="
echo ""

# Stop port-forward
echo "🛑 Stopping port-forward..."
"$SCRIPT_DIR/stop-port-forward.sh" 2>/dev/null || true

# Delete namespaces (this deletes all resources within them)
echo ""
echo "🗑️  Deleting namespaces..."

kubectl --context $CONTEXT delete namespace opamp-control 2>/dev/null && echo "   Deleted opamp-control" || echo "   opamp-control not found"
kubectl --context $CONTEXT delete namespace opamp-edge 2>/dev/null && echo "   Deleted opamp-edge" || echo "   opamp-edge not found"

echo ""
echo "✅ Teardown complete!"
echo ""
echo "Note: Minikube is still running. To stop it:"
echo "   minikube stop -p control-plane"
echo ""
echo "To delete minikube completely:"
echo "   minikube delete -p control-plane"
