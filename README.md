# OpAMP POC - Remote Edge Device Management

Complete implementation of OpenTelemetry's OpAMP protocol for remotely managing Fluent Bit log collectors on edge devices.

---

## 🎯 What This POC Demonstrates

### Core Capabilities

| Capability | Description | Status |
|------------|-------------|--------|
| **Remote Management** | Control edge devices from cloud UI | ✅ Working |
| **OpAMP Protocol** | Standard OpenTelemetry management protocol | ✅ Implemented |
| **One-Way Toggle** | Enable data emission (OFF→ON only) | ✅ Working |
| **Hot Reload** | Config updates without pod restarts | ✅ Working |
| **Auto-Registration** | Devices appear in UI when connected | ✅ Working |
| **Heartbeat Tracking** | 2-minute timeout for stale detection | ✅ Working |
| **Runtime Monitoring** | Devices report actual Fluent Bit state (30s interval) | ✅ Working |
| **Separate Pods** | Device-Agent + Fluent Bit isolated for stability | ✅ Working |
| **Shared Storage** | PVC (ReadWriteMany) for config sharing | ✅ Working |
| **Web Dashboard** | Real-time device status and control | ✅ Working |

### Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│              Cloud (Minikube: opamp-control namespace)         │
│                                                                │
│  ┌───────────────────┐         ┌────────────────────────┐     │
│  │   OpAMP Server    │◄─OpAMP──┤  OpAMP Supervisor      │     │
│  │   Web UI + API    │         │  gRPC Server :50051    │     │
│  │   Port: 4321      │         │  Device Registry       │     │
│  └───────────────────┘         └───────────┬────────────┘     │
│           │                                │                   │
│           │ HTTP                           │ gRPC              │
│           ▼                                │ (per device)      │
│     User Browser                           │                   │
│   localhost:8080                           │                   │
└────────────────────────────────────────────┼───────────────────┘
                                             │
                    ┌────────────────────────┼────────────────────┐
                    │                        │                    │
┌───────────────────┼────────────────────────┼────────────────────┼───┐
│                   │    Edge (opamp-edge)   │                    │   │
│                   ▼                        ▼                    ▼   │
│          ┌─────────────┐          ┌─────────────┐      ┌─────────┐ │
│          │  Device-1   │          │  Device-2   │ ...  │Device-N │ │
│          │   (gRPC)    │          │   (gRPC)    │      │ (gRPC)  │ │
│          └─────────────┘          └─────────────┘      └─────────┘ │
└────────────────────────────────────────────────────────────────────┘

Each Device:
┌─────────────────────────────────────────────────────┐
│                    Device-N                         │
│                                                     │
│  ┌─────────────────┐      ┌─────────────────────┐  │
│  │  Device-Agent   │      │     Fluent Bit      │  │
│  │     (Pod 1)     │      │      (Pod 2)        │  │
│  │                 │      │                     │  │
│  │ • gRPC client   │      │ • Log collector     │  │
│  │ • Config writer │      │ • Hot reload :2020  │  │
│  │ • Reload caller │      │ • Reads from PVC    │  │
│  └────────┬────────┘      └──────────┬──────────┘  │
│           │                          │             │
│           │    Shared PVC (R/W)      │             │
│           └──────────┬───────────────┘             │
│                      │                             │
│              /shared-config/fluent-bit.conf        │
└─────────────────────────────────────────────────────┘
```

### Why Separate Pods?

Each device has **2 pods** sharing 1 PVC:

1. **Device-Agent Pod**
   - Connects to Supervisor via gRPC
   - Receives config updates
   - Writes to shared PVC
   - Calls Fluent Bit reload API
   - Reports runtime state

2. **Fluent Bit Pod**
   - Reads config from shared PVC
   - Hot reloads automatically
   - Emits logs when enabled
   - Exposes API on port 2020

**Benefits:**
- **Zero Downtime**: Config updates without restart
- **Isolation**: One pod crash doesn't affect the other
- **Shared Config**: Both pods see same file via ReadWriteMany PVC

---

## 📋 Prerequisites

### macOS Requirements

```bash
# Install via Homebrew
brew install --cask docker     # Docker Desktop
brew install minikube          # Local Kubernetes
brew install kubectl           # Kubernetes CLI
brew install jq                # JSON processor
brew install go                # Go 1.21+
```

### System Requirements
- **CPU**: 4+ cores
- **RAM**: 6 GB minimum (8 GB recommended)
- **Disk**: 20 GB free space

---

## 📦 Clone Repositories

This POC requires 3 repositories to be cloned as siblings in the same directory:

```bash
# Create workspace directory
mkdir opamp-poc && cd opamp-poc

# Clone all three repos
git clone <opamp-server-repo-url> opamp-server
git clone <opamp-supervisor-repo-url> opamp-supervisor
git clone <opamp-device-agent-repo-url> opamp-device-agent
```

Your directory structure should look like:
```
opamp-poc/
├── opamp-server/        # This repo (main)
├── opamp-supervisor/    # Companion repo
└── opamp-device-agent/  # Companion repo
```

---

## 🚀 Quick Setup (One Command)

```bash
cd opamp-server
./scripts/setup.sh
```

This script automatically:
1. ✅ Starts minikube (if not running)
2. ✅ Creates namespaces (opamp-control, opamp-edge)
3. ✅ Builds all Docker images
4. ✅ Deploys cloud components (Server + Supervisor)
5. ✅ Deploys 2 edge devices (device-1, device-2)
6. ✅ Starts port-forward for UI access

After setup, access the UI at: **http://localhost:8080**

### Teardown
```bash
./scripts/teardown.sh
```

---

## 🔧 Manual Setup (Step by Step)

<details>
<summary>Click to expand manual setup instructions</summary>

### 1. Start Minikube
```bash
minikube start -p control-plane --cpus=4 --memory=8192 --disk-size=20g
```

### 2. Create Namespaces
```bash
kubectl --context control-plane create namespace opamp-control
kubectl --context control-plane create namespace opamp-edge
```

### 3. Build All Images
```bash
# Set Docker to use Minikube's daemon
eval $(minikube -p control-plane docker-env)

# Build server
cd opamp-server
docker build -t opamp-server:v1 .

# Build supervisor
cd ../opamp-supervisor
docker build -t opamp-supervisor:v1 .

# Build device-agent
cd ../opamp-device-agent
docker build -t opamp-device-agent:v1 .
```

### 4. Deploy Cloud Components
```bash
# Deploy OpAMP Server
cd ../opamp-server
kubectl --context control-plane apply -f opamp-server.yaml

# Deploy OpAMP Supervisor
cd ../opamp-supervisor
kubectl --context control-plane apply -f k8s/supervisor.yaml

# Wait for pods to be ready
kubectl --context control-plane wait --for=condition=available --timeout=60s \
  deployment/opamp-server deployment/opamp-supervisor -n opamp-control
```

### 5. Deploy Edge Devices
```bash
cd ../opamp-device-agent

# Add devices dynamically (no hardcoded YAML needed!)
./scripts/add-device.sh 1
./scripts/add-device.sh 2
```

### 6. Start Port-Forward (Persistent)
```bash
cd ../opamp-server
./scripts/start-port-forward.sh
```

### 7. Access UI
```bash
open http://localhost:8080
```

</details>

---

## 🎮 Using the System

### View Devices via API
```bash
curl -s http://localhost:8080/api/devices | jq '.devices[] | {id, connected, emission_enabled}'
```

Expected output:
```json
{
  "id": "device-1",
  "connected": true,
  "emission_enabled": false
}
{
  "id": "device-2",
  "connected": true,
  "emission_enabled": false
}
```

### Enable Data Emission via UI
1. Open http://localhost:8080
2. Click toggle for a device
3. Toggle switches to ON (locked)
4. Device starts emitting logs

### Enable Data Emission via API
```bash
curl -X POST http://localhost:8080/api/devices/config \
  -H "Content-Type: application/json" \
  -d '{"devices": ["device-1"], "setEmission": true}'
```

### Verify Logs Flowing
```bash
kubectl --context control-plane logs -n opamp-edge -l app=fluentbit-device-1 --tail=10 -f
```

Expected output:
```json
{"date":1768817248.726683,"message":"test log","level":"info"}
{"date":1768817249.726873,"message":"test log","level":"info"}
{"date":1768817250.726968,"message":"test log","level":"info"}
```

(1 log per second)

---

## 🔧 Common Operations

### Check Pod Status
```bash
# Cloud components
kubectl --context control-plane get pods -n opamp-control

# Edge devices
kubectl --context control-plane get pods -n opamp-edge
```

### View Logs
```bash
# Server logs
kubectl --context control-plane logs -n opamp-control -l app=opamp-server -f

# Supervisor logs
kubectl --context control-plane logs -n opamp-control -l app=opamp-supervisor -f

# Device-agent logs
kubectl --context control-plane logs -n opamp-edge -l app=device-agent-1 -f

# Fluent Bit logs
kubectl --context control-plane logs -n opamp-edge -l app=fluentbit-device-1 -f
```

### Restart Components After Code Changes
```bash
# Rebuild image
eval $(minikube -p control-plane docker-env)
cd opamp-server  # or opamp-supervisor, opamp-device-agent
docker build -t <image-name>:<version> .

# Restart deployment
kubectl --context control-plane rollout restart deployment/<name> -n <namespace>
```

### Stop/Restart Port-Forward
```bash
# Stop
cd opamp-server
./scripts/stop-port-forward.sh

# Start (persistent)
./scripts/start-port-forward.sh
```

---

## 🗑️ Cleanup

### Remove All Deployments
```bash
cd opamp-server
./scripts/teardown.sh
```

Or manually:
```bash
# Remove devices
cd opamp-device-agent
./scripts/remove-device.sh 1
./scripts/remove-device.sh 2

# Delete namespaces
kubectl --context control-plane delete namespace opamp-control
kubectl --context control-plane delete namespace opamp-edge

# Stop port-forward
cd opamp-server
./scripts/stop-port-forward.sh
```

### Stop/Delete Minikube
```bash
# Stop (preserves everything)
minikube stop -p control-plane

# Delete completely
minikube delete -p control-plane
```

---

## 📊 System Behavior

### Device Lifecycle

```
1. Device pods start
         │
         ▼
2. Device-Agent connects to Supervisor (gRPC)
         │
         ▼
3. Supervisor registers device in registry
         │
         ▼
4. Supervisor reports to OpAMP Server (OpAMP)
         │
         ▼
5. Device appears in UI (connected, emission OFF)
         │
         ▼
6. User clicks toggle to enable emission
         │
         ▼
7. Server → Supervisor → Device-Agent (config push)
         │
         ▼
8. Device-Agent writes config to PVC
         │
         ▼
9. Device-Agent calls Fluent Bit reload API
         │
         ▼
10. Fluent Bit hot reloads (no restart)
         │
         ▼
11. Fluent Bit starts emitting logs ✅
```

### Heartbeat System

- Device-Agent sends messages every **30 seconds**
- Supervisor updates `LastSeen` timestamp
- If no message for **2 minutes** → device marked disconnected
- Disconnected devices removed from UI automatically

### One-Way Toggle Design

**Why can't you turn OFF emission?**

Fluent Bit's hot reload doesn't cleanly support disabling all inputs/outputs. Instead of risking broken configs, the design is:

- **OFF → ON**: Allowed (adds config)
- **ON → OFF**: Blocked (prevents issues)
- **Policy**: Reduce data volume, don't stop collection

---

## 🐛 Troubleshooting

### UI Shows No Devices

**Check:**
```bash
# Are devices pods running?
kubectl --context control-plane get pods -n opamp-edge

# Are device-agents connected?
kubectl --context control-plane logs -n opamp-edge -l app=device-agent-1 | grep "Connected"

# Is supervisor receiving connections?
kubectl --context control-plane logs -n opamp-control -l app=opamp-supervisor | grep "device-1"
```

### Toggle Not Working

**Check:**
```bash
# Did device receive config?
kubectl --context control-plane logs -n opamp-edge -l app=device-agent-1 | grep "ConfigPush"

# Was reload API called?
kubectl --context control-plane logs -n opamp-edge -l app=device-agent-1 | grep "reload API"

# Did Fluent Bit reload?
kubectl --context control-plane logs -n opamp-edge -l app=fluentbit-device-1 | tail -20
```

### Port-Forward Died

**Restart:**
```bash
cd opamp-server
./scripts/stop-port-forward.sh
./scripts/start-port-forward.sh
```

Check logs:
```bash
tail -f /tmp/opamp-port-forward.log
```

### PVC Mount Issues

**Verify:**
```bash
# Check PVC status
kubectl --context control-plane get pvc -n opamp-edge

# Check both pods mount same PVC
kubectl --context control-plane describe pod <device-agent-pod> -n opamp-edge | grep -A5 "Volumes"
kubectl --context control-plane describe pod <fluentbit-pod> -n opamp-edge | grep -A5 "Volumes"
```

---

## 📁 Repository Structure

```
opamp-server/
├── cmd/server/main.go          # Server entry point
├── internal/ui/dashboard.html  # Web UI
├── opamp-server.yaml          # K8s deployment
├── scripts/
│   ├── setup.sh               # One-command full setup
│   ├── teardown.sh            # Remove all resources
│   ├── start-port-forward.sh  # Persistent port-forward
│   ├── stop-port-forward.sh   # Stop port-forward
│   ├── start-ui-access.sh     # Start UI access
│   └── stop-ui-access.sh      # Stop UI access
└── README.md                  # This file

opamp-supervisor/
├── cmd/supervisor/main.go     # Supervisor entry point
├── internal/
│   ├── server/control.go      # gRPC server
│   ├── server/opamp_bridge.go # OpAMP client
│   └── runtime/persistence.go # Device registry
└── k8s/supervisor.yaml        # K8s deployment

opamp-device-agent/
├── main.go                    # Device-agent entry point
├── k8s/                       # (empty - devices created dynamically)
├── scripts/
│   ├── add-device.sh         # Dynamically add devices
│   └── remove-device.sh      # Remove devices
└── Dockerfile                 # Container build
```

---

## 🔑 Key Files

### Server
- **[internal/ui/dashboard.html](internal/ui/dashboard.html)** - Web UI with device list and toggles
- **[cmd/server/main.go](cmd/server/main.go)** - API handlers, OpAMP server logic

### Supervisor
- **[internal/server/control.go](../opamp-supervisor/internal/server/control.go)** - gRPC server for devices
- **[internal/runtime/persistence.go](../opamp-supervisor/internal/runtime/persistence.go)** - Device registry and heartbeat

### Device-Agent
- **[main.go](../opamp-device-agent/main.go)** - Config management, hot reload logic

---

## ⏱️ Timing

- **First-time setup**: 10-15 minutes
- **Add 1 device**: ~30 seconds
- **Config update**: ~2 seconds (hot reload)
- **Device appears in UI**: ~3 seconds after connection

---

## 🎓 Learn More

- **OpAMP Spec**: https://opentelemetry.io/docs/specs/opamp/
- **Fluent Bit**: https://docs.fluentbit.io/
- **Hot Reload API**: https://docs.fluentbit.io/manual/administration/hot-reload

---

**Questions?** Check logs first - they show exactly what's happening! 📝
