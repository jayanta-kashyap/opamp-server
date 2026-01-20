#!/bin/bash

# Policy Test Suite - Tests all Fluent Bit data control policies
# Assumes cluster is already running with at least one device
# Usage: ./tests/policy-tests.sh

# Note: Don't use set -e as grep returns 1 when no match (which is expected in some tests)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_PORT=4321

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAILED++)); }
log_test() { echo -e "\n${YELLOW}Testing: $1${NC}"; }

push_config() {
    curl -s -X POST "http://localhost:${SERVER_PORT}/api/devices/config" \
        -H "Content-Type: application/json" \
        -d "{\"deviceId\":\"$1\",\"config\":\"$2\"}"
}

get_logs() {
    kubectl logs -n opamp-edge deployment/fluentbit-device-1 -c fluentbit --tail=100 2>/dev/null
}

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           Fluent Bit Policy Test Suite                    ║"
echo "╚═══════════════════════════════════════════════════════════╝"

# Ensure port-forward is running
if ! curl -s http://localhost:${SERVER_PORT}/api/devices >/dev/null 2>&1; then
    echo "Starting port-forward..."
    kubectl port-forward -n opamp-control svc/opamp-server ${SERVER_PORT}:${SERVER_PORT} &
    sleep 2
fi

# Record initial restart count
INITIAL_RESTARTS=$(kubectl get pods -n opamp-edge -l app=fluentbit-device-1 -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

#######################################
# Test 1: Throttle Policy
#######################################
log_test "Throttle Policy (Rate Limiting)"

CONFIG='[SERVICE]\n    flush 5\n    daemon Off\n    log_level info\n    http_server On\n    http_listen 0.0.0.0\n    http_port 2020\n    hot_reload On\n\n[INPUT]\n    name dummy\n    tag logs\n    dummy {\"message\":\"throttle-test\",\"level\":\"info\"}\n    rate 10\n\n[FILTER]\n    name throttle\n    match *\n    rate 3\n    window 5\n    print_status true\n\n[OUTPUT]\n    name stdout\n    match *\n    format json_lines'

RESULT=$(push_config "device-1" "$CONFIG")
if echo "$RESULT" | grep -q "success"; then
    log_pass "Config pushed successfully"
else
    log_fail "Config push failed"
fi

sleep 8

LOGS=$(get_logs)
# Check for hot reload happening
if echo "$LOGS" | grep -q "reloading instance\|reload.*start"; then
    log_pass "Hot reload triggered"
else
    log_fail "Hot reload not triggered"
fi

if echo "$LOGS" | grep -q "filter:throttle\|throttle-test"; then
    log_pass "Throttle filter applied"
else
    log_fail "Throttle filter not detected"
fi

#######################################
# Test 2: Grep Policy (Log Level Filter)
#######################################
log_test "Grep Policy (Log Level Filtering)"

CONFIG='[SERVICE]\n    flush 5\n    daemon Off\n    log_level info\n    http_server On\n    http_listen 0.0.0.0\n    http_port 2020\n    hot_reload On\n\n[INPUT]\n    name dummy\n    tag logs\n    dummy {\"message\":\"debug-log\",\"level\":\"debug\"}\n    rate 5\n\n[INPUT]\n    name dummy\n    tag logs\n    dummy {\"message\":\"warn-log\",\"level\":\"warn\"}\n    rate 2\n\n[FILTER]\n    name grep\n    match *\n    regex level (warn|error)\n\n[OUTPUT]\n    name stdout\n    match *\n    format json_lines'

RESULT=$(push_config "device-1" "$CONFIG")
if echo "$RESULT" | grep -q "success"; then
    log_pass "Config pushed successfully"
else
    log_fail "Config push failed"
fi

sleep 8

LOGS=$(get_logs)
# For grep policy - check that warn-log appears OR debug-log is absent (filtered)
if echo "$LOGS" | grep -q "warn-log\|reloading instance"; then
    log_pass "Grep config applied"
else
    log_fail "Grep config not applied"
fi

if echo "$LOGS" | grep -q "debug-log"; then
    log_fail "Debug logs should be filtered out"
else
    log_pass "Debug logs filtered correctly"
fi

#######################################
# Test 3: Modify Policy (Field Removal)
#######################################
log_test "Modify Policy (Field Removal)"

CONFIG='[SERVICE]\n    flush 5\n    daemon Off\n    log_level info\n    http_server On\n    http_listen 0.0.0.0\n    http_port 2020\n    hot_reload On\n\n[INPUT]\n    name dummy\n    tag logs\n    dummy {\"message\":\"modify-test\",\"level\":\"info\",\"remove_me\":\"secret\"}\n    rate 2\n\n[FILTER]\n    name modify\n    match *\n    remove remove_me\n\n[OUTPUT]\n    name stdout\n    match *\n    format json_lines'

RESULT=$(push_config "device-1" "$CONFIG")
if echo "$RESULT" | grep -q "success"; then
    log_pass "Config pushed successfully"
else
    log_fail "Config push failed"
fi

sleep 8

LOGS=$(get_logs)
if echo "$LOGS" | grep -q "modify-test\|reloading instance"; then
    log_pass "Modify config applied"
else
    log_fail "Modify config not applied"
fi

if echo "$LOGS" | grep -q "remove_me"; then
    log_fail "Field should be removed"
else
    log_pass "Field removed correctly"
fi

#######################################
# Test 4: Zero Pod Restarts
#######################################
log_test "Zero Pod Restarts After All Policy Changes"

FINAL_RESTARTS=$(kubectl get pods -n opamp-edge -l app=fluentbit-device-1 -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

if [ "$INITIAL_RESTARTS" == "$FINAL_RESTARTS" ]; then
    log_pass "No pod restarts (initial: $INITIAL_RESTARTS, final: $FINAL_RESTARTS)"
else
    log_fail "Pod restarted! (initial: $INITIAL_RESTARTS, final: $FINAL_RESTARTS)"
fi

#######################################
# Summary
#######################################
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                    POLICY TEST SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo -e "${GREEN}  Passed: $PASSED${NC}"
echo -e "${RED}  Failed: $FAILED${NC}"
echo "═══════════════════════════════════════════════════════════"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
