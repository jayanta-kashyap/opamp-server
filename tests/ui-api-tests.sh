#!/bin/bash

# UI/API Feature Test Suite
# Tests new features: emission control, auto-enable, API endpoints
# Usage: ./tests/ui-api-tests.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_PORT=4321

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAILED++)); }
log_test() { echo -e "\n${YELLOW}Testing: $1${NC}"; }
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           UI/API Feature Test Suite                       ║"
echo "╚═══════════════════════════════════════════════════════════╝"

# Ensure port-forward is running
if ! curl -s http://localhost:${SERVER_PORT}/api/devices >/dev/null 2>&1; then
    echo "Starting port-forward..."
    kubectl port-forward -n opamp-control svc/opamp-server ${SERVER_PORT}:${SERVER_PORT} &
    sleep 3
fi

#######################################
# Test 1: List Devices API
#######################################
log_test "GET /api/devices - List all devices"

RESPONSE=$(curl -s http://localhost:${SERVER_PORT}/api/devices)

if echo "$RESPONSE" | grep -q '"devices"'; then
    log_pass "Response contains devices array"
else
    log_fail "Response missing devices array"
fi

DEVICE_COUNT=$(echo "$RESPONSE" | jq '.devices | length' 2>/dev/null || echo "0")
if [ "$DEVICE_COUNT" -ge 1 ]; then
    log_pass "Found $DEVICE_COUNT device(s)"
else
    log_fail "No devices found"
fi

# Check device structure
if echo "$RESPONSE" | jq '.devices[0]' 2>/dev/null | grep -q '"emission_enabled"'; then
    log_pass "Device has emission_enabled field"
else
    log_fail "Device missing emission_enabled field"
fi

#######################################
# Test 2: Get Device Config API
#######################################
log_test "GET /api/devices/{id}/config - Get device config"

CONFIG_RESPONSE=$(curl -s http://localhost:${SERVER_PORT}/api/devices/device-1/config)

if echo "$CONFIG_RESPONSE" | grep -q '"config"'; then
    log_pass "Response contains config field"
else
    log_fail "Response missing config field"
fi

if echo "$CONFIG_RESPONSE" | grep -q '\[SERVICE\]'; then
    log_pass "Config contains SERVICE section"
else
    log_fail "Config missing SERVICE section"
fi

#######################################
# Test 3: Push Config with Auto-Enable Emission
#######################################
log_test "POST /api/devices/config with setEmission:true"

# Find a device with emission OFF
DEVICE_OFF=$(curl -s http://localhost:${SERVER_PORT}/api/devices | jq -r '.devices[] | select(.emission_enabled == false) | .id' | head -1)

if [ -z "$DEVICE_OFF" ]; then
    log_info "All devices have emission ON, using device-10 for test"
    DEVICE_OFF="device-10"
fi

log_info "Testing with device: $DEVICE_OFF"

# Push config with setEmission: true
CONFIG='[SERVICE]\n    flush 5\n    daemon Off\n    log_level info\n    http_server On\n    http_listen 0.0.0.0\n    http_port 2020\n    hot_reload On\n\n[INPUT]\n    name dummy\n    tag logs\n    dummy {\"message\":\"auto-emission-test\",\"level\":\"info\"}\n    rate 1\n\n[OUTPUT]\n    name stdout\n    match *\n    format json_lines'

PUSH_RESULT=$(curl -s -X POST "http://localhost:${SERVER_PORT}/api/devices/config" \
    -H "Content-Type: application/json" \
    -d "{\"deviceId\":\"$DEVICE_OFF\",\"config\":\"$CONFIG\",\"setEmission\":true}")

if echo "$PUSH_RESULT" | grep -q '"success":true'; then
    log_pass "Config pushed successfully"
else
    log_fail "Config push failed: $PUSH_RESULT"
fi

# Wait for state to update
sleep 3

# Verify emission was enabled
EMISSION_STATE=$(curl -s http://localhost:${SERVER_PORT}/api/devices | jq -r ".devices[] | select(.id == \"$DEVICE_OFF\") | .emission_enabled")

if [ "$EMISSION_STATE" == "true" ]; then
    log_pass "Emission auto-enabled for $DEVICE_OFF"
else
    log_fail "Emission not enabled (state: $EMISSION_STATE)"
fi

#######################################
# Test 4: Config Persistence Check
#######################################
log_test "Config persistence - verify config saved to device"

# Get config from API
API_CONFIG=$(curl -s http://localhost:${SERVER_PORT}/api/devices/$DEVICE_OFF/config | jq -r '.config')

if echo "$API_CONFIG" | grep -q "auto-emission-test"; then
    log_pass "Config persisted with custom message"
else
    log_fail "Config not persisted correctly"
fi

# Verify on actual pod
POD_CONFIG=$(kubectl exec -n opamp-edge deployment/device-agent-${DEVICE_OFF#device-} -- cat /shared-config/fluent-bit.conf 2>/dev/null)

if echo "$POD_CONFIG" | grep -q "auto-emission-test"; then
    log_pass "Config verified on pod"
else
    log_fail "Config not found on pod"
fi

#######################################
# Test 5: Dashboard HTML Served
#######################################
log_test "Dashboard HTML served correctly"

DASHBOARD=$(curl -s http://localhost:${SERVER_PORT}/)

if echo "$DASHBOARD" | grep -q "OpAMP"; then
    log_pass "Dashboard HTML contains OpAMP"
else
    log_fail "Dashboard HTML missing OpAMP title"
fi

if echo "$DASHBOARD" | grep -q "dual-panel-container"; then
    log_pass "Dashboard has dual-panel layout"
else
    log_fail "Dashboard missing dual-panel layout"
fi

if echo "$DASHBOARD" | grep -q "policy-disabled-overlay"; then
    log_pass "Dashboard has policy overlay feature"
else
    log_fail "Dashboard missing policy overlay"
fi

if echo "$DASHBOARD" | grep -q "Raw Configuration"; then
    log_pass "Dashboard has Raw Configuration section"
else
    log_fail "Dashboard missing Raw Configuration section"
fi

if echo "$DASHBOARD" | grep -q "Data Policies"; then
    log_pass "Dashboard has Data Policies section"
else
    log_fail "Dashboard missing Data Policies section"
fi

#######################################
# Test 6: Natural Sorting in UI
#######################################
log_test "Device list natural sorting (1, 2, 3... not 1, 10, 11)"

# The UI sorts in JavaScript, but we can verify the sort function exists
if echo "$DASHBOARD" | grep -q "Natural sort"; then
    log_pass "Natural sort comment present in code"
else
    log_fail "Natural sort not implemented"
fi

if echo "$DASHBOARD" | grep -q "regex.*\\\\d"; then
    log_pass "Natural sort regex pattern present"
else
    log_fail "Natural sort regex pattern missing"
fi

#######################################
# Test 7: Emission Toggle Lock
#######################################
log_test "Emission toggle lock feature"

if echo "$DASHBOARD" | grep -q "toggle-switch.*locked"; then
    log_pass "Toggle lock CSS class present"
else
    log_fail "Toggle lock CSS missing"
fi

if echo "$DASHBOARD" | grep -q "cannot be turned off"; then
    log_pass "Emission lock warning present"
else
    log_fail "Emission lock warning missing"
fi

#######################################
# Test 8: Multiple Device Support
#######################################
log_test "Multiple device support"

TOTAL_DEVICES=$(curl -s http://localhost:${SERVER_PORT}/api/devices | jq '.devices | length')

if [ "$TOTAL_DEVICES" -gt 1 ]; then
    log_pass "Multiple devices registered: $TOTAL_DEVICES"
else
    log_fail "Only $TOTAL_DEVICES device(s) - expected more"
fi

# Check that devices are connected
CONNECTED=$(curl -s http://localhost:${SERVER_PORT}/api/devices | jq '[.devices[] | select(.connected == true)] | length')

if [ "$CONNECTED" -eq "$TOTAL_DEVICES" ]; then
    log_pass "All $CONNECTED devices connected"
else
    log_fail "Only $CONNECTED/$TOTAL_DEVICES devices connected"
fi

#######################################
# Test 9: Emission Stats
#######################################
log_test "Emission statistics tracking"

EMITTING=$(curl -s http://localhost:${SERVER_PORT}/api/devices | jq '[.devices[] | select(.emission_enabled == true)] | length')

log_info "Devices emitting: $EMITTING / $TOTAL_DEVICES"

if [ "$EMITTING" -ge 1 ]; then
    log_pass "At least 1 device emitting"
else
    log_fail "No devices emitting"
fi

#######################################
# Test 10: Invalid Device Handling
#######################################
log_test "Invalid device handling"

INVALID_RESULT=$(curl -s http://localhost:${SERVER_PORT}/api/devices/nonexistent-device/config)

if echo "$INVALID_RESULT" | grep -q "error\|not found\|null"; then
    log_pass "Invalid device handled gracefully"
else
    log_fail "Invalid device not handled properly"
fi

#######################################
# Summary
#######################################
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                   UI/API TEST SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo -e "${GREEN}  Passed: $PASSED${NC}"
echo -e "${RED}  Failed: $FAILED${NC}"
echo "═══════════════════════════════════════════════════════════"

if [ $FAILED -gt 0 ]; then
    exit 1
fi

echo -e "\n${GREEN}All UI/API tests passed!${NC}"
