#!/bin/bash

# Quick smoke test - validates basic POC functionality
# Usage: ./tests/smoke-test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🔥 OpAMP POC Smoke Test"
echo "========================"

# Check prerequisites
echo -n "Checking minikube... "
if minikube status -p control-plane >/dev/null 2>&1; then
    echo "✅"
else
    echo "❌ (minikube not running)"
    exit 1
fi

echo -n "Checking namespaces... "
if kubectl get ns opamp-control >/dev/null 2>&1 && kubectl get ns opamp-edge >/dev/null 2>&1; then
    echo "✅"
else
    echo "❌ (namespaces missing)"
    exit 1
fi

echo -n "Checking control plane... "
if kubectl get pods -n opamp-control -l app=opamp-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
    echo "✅"
else
    echo "❌ (server not running)"
    exit 1
fi

echo -n "Checking supervisor... "
if kubectl get pods -n opamp-control -l app=opamp-supervisor -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
    echo "✅"
else
    echo "❌ (supervisor not running)"
    exit 1
fi

echo -n "Checking devices... "
DEVICE_COUNT=$(kubectl get pods -n opamp-edge -l app=device-agent-1 --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$DEVICE_COUNT" -ge 1 ]; then
    echo "✅ ($DEVICE_COUNT device(s))"
else
    echo "❌ (no devices)"
    exit 1
fi

echo -n "Checking Fluent Bit... "
if kubectl get pods -n opamp-edge -l app=fluentbit-device-1 -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
    echo "✅"
else
    echo "❌ (fluentbit not running)"
    exit 1
fi

echo -n "Checking API accessibility... "
# Check if port-forward is running or try to access NodePort
if curl -s --connect-timeout 2 http://localhost:4321/api/devices >/dev/null 2>&1; then
    echo "✅"
else
    echo "⚠️  (port-forward not running, starting...)"
    kubectl port-forward -n opamp-control svc/opamp-server 4321:4321 &
    sleep 2
    if curl -s http://localhost:4321/api/devices >/dev/null 2>&1; then
        echo "   ✅ Port-forward started"
    else
        echo "   ❌ Cannot access API"
        exit 1
    fi
fi

echo -n "Checking device registration... "
DEVICES=$(curl -s http://localhost:4321/api/devices 2>/dev/null)
if echo "$DEVICES" | grep -q "device-1"; then
    echo "✅"
else
    echo "❌ (device not registered)"
    exit 1
fi

echo ""
echo "========================"
echo "🎉 All smoke tests passed!"
echo ""
echo "Dashboard: http://localhost:4321"
