# OpAMP POC Test Framework

This directory contains integration tests for the OpAMP POC.

## Test Scripts

| Script | Purpose | Duration |
|--------|---------|----------|
| `smoke-test.sh` | Quick health check of running deployment | ~5 sec |
| `policy-tests.sh` | Test all Fluent Bit policies (throttle, grep, modify) | ~30 sec |
| `run-tests.sh` | Full integration test suite with setup/teardown | ~5 min |

## Quick Start

### Smoke Test (requires running deployment)
```bash
./tests/smoke-test.sh
```

### Policy Tests (requires running deployment with device-1)
```bash
./tests/policy-tests.sh
```

### Full Test Suite (clean setup + all tests)
```bash
./tests/run-tests.sh
```

### Run Single Test
```bash
./tests/run-tests.sh throttle
./tests/run-tests.sh grep
./tests/run-tests.sh modify
./tests/run-tests.sh restarts
```

## Prerequisites

1. **Minikube** running with profile `control-plane`
2. **kubectl** configured to use the minikube context
3. **Docker images** built and available in minikube:
   - `opamp-server:v1`
   - `opamp-supervisor:v10`
   - `opamp-device-agent:v8`

## Test Categories

### 1. Deployment Tests
- Control plane pods running
- Device agent pods running
- Fluent Bit pods running

### 2. OpAMP Protocol Tests
- Device registration via supervisor
- Config push via AgentRemoteConfig
- Status reporting

### 3. Policy Tests
- **Throttle**: Rate limiting (e.g., 3 logs per 5 seconds)
- **Grep**: Log level filtering (keep only warn/error)
- **Modify**: Field removal (reduce payload size)

### 4. Hot Reload Tests
- Config changes without pod restarts
- Fluent Bit hot reload API working
- Zero restart count after multiple config changes

## Expected Output

```
╔═══════════════════════════════════════════════════════════╗
║           OpAMP POC Integration Test Suite                ║
╚═══════════════════════════════════════════════════════════╝

[PASS] OpAMP Server is running
[PASS] OpAMP Supervisor is running
[PASS] Device Agent-1 is running
[PASS] Fluent Bit device-1 is running
[PASS] Device-1 registered with server
[PASS] Config push successful
[PASS] Throttle filter active
[PASS] Debug logs filtered correctly
[PASS] Field removed correctly
[PASS] No pod restarts

════════════════════════════════════════════════════════════
                      TEST SUMMARY
════════════════════════════════════════════════════════════
  Passed:  15
  Failed:  0
  Skipped: 0
════════════════════════════════════════════════════════════
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLEANUP_NAMESPACES` | `false` | Delete namespaces after tests |
| `SERVER_PORT` | `4321` | Port for OpAMP server API |
| `TIMEOUT` | `60` | Timeout for pod readiness |

## CI/CD Integration

For automated testing in CI pipelines:

```yaml
# Example GitHub Actions step
- name: Run OpAMP POC Tests
  run: |
    minikube start --profile control-plane
    eval $(minikube docker-env -p control-plane)
    # Build images...
    ./tests/run-tests.sh
```
