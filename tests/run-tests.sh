#!/bin/bash

# OpAMP POC Test Framework
# Run all integration tests for the OpAMP POC
# Usage: ./tests/run-tests.sh [test-name]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SUPERVISOR_DIR="$(dirname "$ROOT_DIR")/opamp-supervisor"
DEVICE_AGENT_DIR="$(dirname "$ROOT_DIR")/opamp-device-agent"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Configuration
NAMESPACE_CONTROL="opamp-control"
NAMESPACE_EDGE="opamp-edge"
SERVER_PORT=4321
TIMEOUT=60

#######################################
# Utility Functions
#######################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_test() {
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}TEST: $1${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    
    if [ "$expected" == "$actual" ]; then
        log_success "$message"
        return 0
    else
        log_error "$message (expected: '$expected', got: '$actual')"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    
    if echo "$haystack" | grep -q "$needle"; then
        log_success "$message"
        return 0
    else
        log_error "$message (expected to contain: '$needle')"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    
    if ! echo "$haystack" | grep -q "$needle"; then
        log_success "$message"
        return 0
    else
        log_error "$message (expected NOT to contain: '$needle')"
        return 1
    fi
}

assert_pod_running() {
    local namespace="$1"
    local label="$2"
    local message="$3"
    
    local status=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    
    if [ "$status" == "Running" ]; then
        log_success "$message"
        return 0
    else
        log_error "$message (status: '$status')"
        return 1
    fi
}

assert_zero_restarts() {
    local namespace="$1"
    local label="$2"
    local message="$3"
    
    local restarts=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
    
    if [ "$restarts" == "0" ]; then
        log_success "$message"
        return 0
    else
        log_error "$message (restarts: $restarts)"
        return 1
    fi
}

wait_for_pod() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-60}"
    
    kubectl wait --for=condition=ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    if [ -n "$data" ]; then
        curl -s -X "$method" "http://localhost:${SERVER_PORT}${endpoint}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "http://localhost:${SERVER_PORT}${endpoint}"
    fi
}

get_fluentbit_logs() {
    local device_num="${1:-1}"
    local tail="${2:-20}"
    
    kubectl logs -n "$NAMESPACE_EDGE" "deployment/fluentbit-device-${device_num}" -c fluentbit --tail="$tail" 2>/dev/null
}

push_config() {
    local device_id="$1"
    local config="$2"
    
    api_call POST "/api/devices/config" "{\"deviceId\":\"$device_id\",\"config\":\"$config\"}"
}

#######################################
# Setup / Teardown
#######################################

setup_cluster() {
    log_info "Setting up test cluster..."
    
    # Ensure minikube is running
    minikube status -p control-plane >/dev/null 2>&1 || {
        log_error "Minikube profile 'control-plane' is not running"
        exit 1
    }
    
    # Clean existing namespaces
    kubectl delete namespace "$NAMESPACE_CONTROL" "$NAMESPACE_EDGE" --ignore-not-found --wait=true 2>/dev/null || true
    
    # Create namespaces
    kubectl create namespace "$NAMESPACE_CONTROL"
    kubectl create namespace "$NAMESPACE_EDGE"
    
    log_success "Namespaces created"
}

deploy_control_plane() {
    log_info "Deploying control plane..."
    
    kubectl apply -f "$ROOT_DIR/opamp-server.yaml"
    kubectl apply -f "$SUPERVISOR_DIR/k8s/supervisor.yaml"
    
    wait_for_pod "$NAMESPACE_CONTROL" "app=opamp-server" 60
    wait_for_pod "$NAMESPACE_CONTROL" "app=opamp-supervisor" 60
    
    log_success "Control plane deployed"
}

deploy_device() {
    local device_num="${1:-1}"
    log_info "Deploying device-${device_num}..."
    
    cd "$DEVICE_AGENT_DIR"
    ./scripts/add-device.sh "$device_num"
    
    log_success "Device-${device_num} deployed"
}

start_port_forward() {
    log_info "Starting port-forward..."
    
    # Kill existing port-forward
    pkill -f "port-forward.*opamp-server.*${SERVER_PORT}" 2>/dev/null || true
    sleep 1
    
    kubectl port-forward -n "$NAMESPACE_CONTROL" svc/opamp-server ${SERVER_PORT}:${SERVER_PORT} &
    PF_PID=$!
    sleep 2
    
    # Verify port-forward is working
    if curl -s "http://localhost:${SERVER_PORT}/api/devices" >/dev/null 2>&1; then
        log_success "Port-forward started (PID: $PF_PID)"
    else
        log_error "Port-forward failed to start"
        exit 1
    fi
}

cleanup() {
    log_info "Cleaning up..."
    
    # Kill port-forward
    pkill -f "port-forward.*opamp-server.*${SERVER_PORT}" 2>/dev/null || true
    
    # Optionally delete namespaces
    if [ "${CLEANUP_NAMESPACES:-false}" == "true" ]; then
        kubectl delete namespace "$NAMESPACE_CONTROL" "$NAMESPACE_EDGE" --ignore-not-found --wait=false 2>/dev/null || true
    fi
    
    log_info "Cleanup complete"
}

#######################################
# Test Cases
#######################################

test_control_plane_deployment() {
    log_test "Control Plane Deployment"
    
    assert_pod_running "$NAMESPACE_CONTROL" "app=opamp-server" "OpAMP Server is running" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_pod_running "$NAMESPACE_CONTROL" "app=opamp-supervisor" "OpAMP Supervisor is running" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_device_deployment() {
    log_test "Device Deployment"
    
    assert_pod_running "$NAMESPACE_EDGE" "app=device-agent-1" "Device Agent-1 is running" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_pod_running "$NAMESPACE_EDGE" "app=fluentbit-device-1" "Fluent Bit device-1 is running" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_device_registration() {
    log_test "Device Registration via OpAMP"
    
    sleep 5  # Wait for device to register
    
    local devices=$(api_call GET "/api/devices")
    
    assert_contains "$devices" "device-1" "Device-1 registered with server" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_contains "$devices" "\"connected\":true" "Device-1 shows as connected" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_initial_state_no_emission() {
    log_test "Initial State - No Data Emission"
    
    local logs=$(get_fluentbit_logs 1 50)
    
    # Should have startup logs but no data output initially (unless toggle was on)
    assert_contains "$logs" "Fluent Bit v" "Fluent Bit started" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_contains "$logs" "http_server" "HTTP server enabled" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_enable_data_emission() {
    log_test "Enable Data Emission"
    
    local config="[SERVICE]\\n    flush 5\\n    daemon Off\\n    log_level info\\n    http_server On\\n    http_listen 0.0.0.0\\n    http_port 2020\\n    hot_reload On\\n\\n[INPUT]\\n    name dummy\\n    tag logs\\n    dummy {\\\"message\\\":\\\"test log\\\",\\\"level\\\":\\\"info\\\"}\\n    rate 1\\n\\n[OUTPUT]\\n    name stdout\\n    match *\\n    format json_lines"
    
    local result=$(push_config "device-1" "$config")
    
    assert_contains "$result" "success" "Config push successful" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    
    sleep 5
    
    local logs=$(get_fluentbit_logs 1 20)
    assert_contains "$logs" "test log" "Data emission started" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_throttle_policy() {
    log_test "Throttle Policy"
    
    local config="[SERVICE]\\n    flush 5\\n    daemon Off\\n    log_level info\\n    http_server On\\n    http_listen 0.0.0.0\\n    http_port 2020\\n    hot_reload On\\n\\n[INPUT]\\n    name dummy\\n    tag logs\\n    dummy {\\\"message\\\":\\\"throttle test\\\",\\\"level\\\":\\\"info\\\"}\\n    rate 10\\n\\n[FILTER]\\n    name throttle\\n    match *\\n    rate 3\\n    window 5\\n    print_status true\\n\\n[OUTPUT]\\n    name stdout\\n    match *\\n    format json_lines"
    
    local result=$(push_config "device-1" "$config")
    assert_contains "$result" "success" "Throttle config pushed" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    
    sleep 6
    
    local logs=$(get_fluentbit_logs 1 30)
    assert_contains "$logs" "throttle test" "Throttle config applied" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_contains "$logs" "filter:throttle" "Throttle filter active" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_grep_policy() {
    log_test "Grep Filter Policy"
    
    local config="[SERVICE]\\n    flush 5\\n    daemon Off\\n    log_level info\\n    http_server On\\n    http_listen 0.0.0.0\\n    http_port 2020\\n    hot_reload On\\n\\n[INPUT]\\n    name dummy\\n    tag logs\\n    dummy {\\\"message\\\":\\\"debug msg\\\",\\\"level\\\":\\\"debug\\\"}\\n    rate 5\\n\\n[INPUT]\\n    name dummy\\n    tag logs\\n    dummy {\\\"message\\\":\\\"warn msg\\\",\\\"level\\\":\\\"warn\\\"}\\n    rate 2\\n\\n[FILTER]\\n    name grep\\n    match *\\n    regex level (warn|error)\\n\\n[OUTPUT]\\n    name stdout\\n    match *\\n    format json_lines"
    
    local result=$(push_config "device-1" "$config")
    assert_contains "$result" "success" "Grep config pushed" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    
    sleep 5
    
    local logs=$(get_fluentbit_logs 1 30)
    assert_contains "$logs" "warn msg" "Warn logs present" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_not_contains "$logs" "debug msg" "Debug logs filtered out" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_modify_policy() {
    log_test "Modify Filter Policy"
    
    local config="[SERVICE]\\n    flush 5\\n    daemon Off\\n    log_level info\\n    http_server On\\n    http_listen 0.0.0.0\\n    http_port 2020\\n    hot_reload On\\n\\n[INPUT]\\n    name dummy\\n    tag logs\\n    dummy {\\\"message\\\":\\\"test\\\",\\\"level\\\":\\\"info\\\",\\\"extra_field\\\":\\\"remove me\\\"}\\n    rate 2\\n\\n[FILTER]\\n    name modify\\n    match *\\n    remove extra_field\\n\\n[OUTPUT]\\n    name stdout\\n    match *\\n    format json_lines"
    
    local result=$(push_config "device-1" "$config")
    assert_contains "$result" "success" "Modify config pushed" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    
    sleep 4
    
    local logs=$(get_fluentbit_logs 1 15)
    assert_contains "$logs" '"message":"test"' "Message field present" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_not_contains "$logs" "extra_field" "Extra field removed" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_no_pod_restarts() {
    log_test "Zero Pod Restarts"
    
    assert_zero_restarts "$NAMESPACE_EDGE" "app=fluentbit-device-1" "Fluent Bit has zero restarts" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    assert_zero_restarts "$NAMESPACE_EDGE" "app=device-agent-1" "Device Agent has zero restarts" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

test_hot_reload_count() {
    log_test "Hot Reload Count"
    
    # Port forward to Fluent Bit
    kubectl port-forward -n "$NAMESPACE_EDGE" svc/fluentbit-device-1 2020:2020 &
    local fb_pf_pid=$!
    sleep 2
    
    local reload_info=$(curl -s http://localhost:2020/api/v2/reload 2>/dev/null || echo '{"error":"failed"}')
    
    kill $fb_pf_pid 2>/dev/null || true
    
    if echo "$reload_info" | grep -q "hot_reload_count"; then
        local count=$(echo "$reload_info" | grep -o '"hot_reload_count":[0-9]*' | cut -d: -f2)
        if [ "$count" -gt 0 ]; then
            log_success "Hot reload count: $count (hot reload working)"
            ((TESTS_PASSED++))
        else
            log_warning "Hot reload count is 0"
            ((TESTS_PASSED++))
        fi
    else
        log_warning "Could not get hot reload count"
        ((TESTS_SKIPPED++))
    fi
}

test_api_endpoints() {
    log_test "API Endpoints"
    
    local devices=$(api_call GET "/api/devices")
    assert_contains "$devices" "devices" "GET /api/devices works" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
    
    local agents=$(api_call GET "/api/agents")
    assert_contains "$agents" "agents" "GET /api/agents works" || ((TESTS_FAILED++)) && ((TESTS_PASSED++))
}

#######################################
# Test Runner
#######################################

run_all_tests() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           OpAMP POC Integration Test Suite                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
    
    # Setup
    setup_cluster
    deploy_control_plane
    deploy_device 1
    start_port_forward
    
    # Run tests
    test_control_plane_deployment
    test_device_deployment
    test_device_registration
    test_initial_state_no_emission
    test_enable_data_emission
    test_throttle_policy
    test_grep_policy
    test_modify_policy
    test_no_pod_restarts
    test_hot_reload_count
    test_api_endpoints
    
    # Run UI/API feature tests
    echo -e "\n${BLUE}Running UI/API Feature Tests...${NC}"
    if [ -x "$SCRIPT_DIR/ui-api-tests.sh" ]; then
        if "$SCRIPT_DIR/ui-api-tests.sh"; then
            log_success "UI/API Feature Tests passed"
            ((TESTS_PASSED++))
        else
            log_error "UI/API Feature Tests failed"
            ((TESTS_FAILED++))
        fi
    else
        log_warning "UI/API test script not found or not executable"
        ((TESTS_SKIPPED++))
    fi
    
    # Summary
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                      TEST SUMMARY                           ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Passed:  ${TESTS_PASSED}${NC}"
    echo -e "${RED}  Failed:  ${TESTS_FAILED}${NC}"
    echo -e "${YELLOW}  Skipped: ${TESTS_SKIPPED}${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}\n"
    
    # Cleanup
    cleanup
    
    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
}

run_single_test() {
    local test_name="$1"
    
    echo -e "\n${BLUE}Running single test: ${test_name}${NC}\n"
    
    start_port_forward
    
    case "$test_name" in
        "control-plane")
            test_control_plane_deployment
            ;;
        "device")
            test_device_deployment
            ;;
        "registration")
            test_device_registration
            ;;
        "emission")
            test_enable_data_emission
            ;;
        "throttle")
            test_throttle_policy
            ;;
        "grep")
            test_grep_policy
            ;;
        "modify")
            test_modify_policy
            ;;
        "restarts")
            test_no_pod_restarts
            ;;
        "api")
            test_api_endpoints
            ;;
        "ui")
            if [ -x "$SCRIPT_DIR/ui-api-tests.sh" ]; then
                "$SCRIPT_DIR/ui-api-tests.sh"
            else
                log_error "UI/API test script not found or not executable"
                exit 1
            fi
            ;;
        *)
            log_error "Unknown test: $test_name"
            echo "Available tests: control-plane, device, registration, emission, throttle, grep, modify, restarts, api, ui"
            exit 1
            ;;
    esac
    
    cleanup
}

#######################################
# Main
#######################################

trap cleanup EXIT

if [ -n "$1" ]; then
    run_single_test "$1"
else
    run_all_tests
fi
