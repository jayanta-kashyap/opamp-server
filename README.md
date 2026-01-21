# OpAMP POC - Remote Edge Device Management

Implementation of OpenTelemetry's [OpAMP protocol](https://opentelemetry.io/docs/specs/opamp/) for remotely managing Fluent Bit log collectors on edge devices.

---

## 📑 Table of Contents

- [What This POC Demonstrates](#-what-this-poc-demonstrates)
  - [Architecture Overview](#architecture-overview)
  - [Core Capabilities](#core-capabilities)
- [Feature Matrix](#-feature-matrix)
  - [Performance & Scale](#performance--scale)
  - [API Endpoints](#api-endpoints)
  - [Dashboard UI Features](#-dashboard-ui-features)
- [OpAMP Protocol Functions Used](#opamp-protocol-functions-used)
  - [Pod Separation Design in the Edge Device](#pod-separation-design-in-the-edge-device)
- [Prerequisites](#-prerequisites)
- [Clone Repositories](#-clone-repositories)
- [Quick Setup (One Command)](#-quick-setup-one-command)
- [Manual Setup (Step by Step)](#-manual-setup-step-by-step)
- [Using the System](#-using-the-system)
  - [Deploy/Remove Devices via UI](#deployrremove-devices-via-ui-poc-provisioner)
  - [Apply Data Policies via UI](#apply-data-policies-via-ui)
  - [Push Custom FluentBit Config](#push-custom-fluentbit-config)
  - [Toggle Data Emission](#toggle-data-emission-via-ui)
- [Common Operations](#-common-operations)
- [Cleanup](#️-cleanup)
- [System Behavior](#-system-behavior)
- [Troubleshooting](#-troubleshooting)
- [Repository Structure](#-repository-structure)
- [Key Files](#-key-files)
- [Timing](#️-timing)
- [Learn More](#-learn-more)

---

## 🎯 What This POC Demonstrates

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
│   localhost:4321                           │                   │
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

### Core Capabilities

| Category | Features |
|----------|----------|
| **Device Management** | Auto-registration, Heartbeat (2min timeout), Runtime monitoring (30s) |
| **Configuration** | Remote config push, Hot reload (zero downtime), PVC persistence |
| **Dashboard** | Device list, Dual-panel view, Real-time config display, Per-device delete buttons |
| **Emission Toggle** | Toggle ON enabled, Toggle OFF disabled in POC (requires custom FluentBit) |
| **Policy-Based Config** | Throttle, Grep (log level filter), Modify (field removal), Live preview |
| **Custom Config Push** | Raw FluentBit config push with pre-populated template |
| **POC Provisioner** | UI-based device deploy/remove (no kubectl needed) |

---

### Performance & Scale

| Max Devices | Config Latency | Hot Reload | Heartbeat | Timeout | Memory/Device |
|-------------|----------------|------------|-----------|---------|---------------|
| 100+ | <500ms | ~50ms | 30s | 2min | ~10MB |

---

### API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Dashboard UI |
| `GET` | `/api/devices` | List all registered devices with status |
| `GET` | `/api/devices/{id}/config` | Get current config for a device |
| `POST` | `/api/devices/config` | Push new config to a device |
| `POST` | `/api/devices/emission` | Toggle data emission for a device |

---

## 🔄 Code Structure & OpAMP Function Interactions

This section shows how the Server and Supervisor components are built and how they use OpAMP protocol functions to communicate.

### How OpAMP Functions Connect the Components

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                        OpAMP Protocol Message Flow                                   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│   ┌─────────────────────┐                           ┌─────────────────────┐          │
│   │    OpAMP SERVER     │◄══════ WebSocket ════════►│   OpAMP SUPERVISOR  │          │
│   │   (opamp-server)    │      (Port 4320)          │  (opamp-supervisor) │          │
│   └─────────────────────┘                           └─────────────────────┘          │
│                                                                                      │
│   SERVER sends to SUPERVISOR:                       SUPERVISOR sends to SERVER:      │
│   ┌───────────────────────────┐                     ┌───────────────────────────┐    │
│   │ ServerToAgent             │                     │ AgentToServer             │    │
│   │ ├─ RemoteConfig           │ ──────────────────► │ ├─ AgentDescription       │    │
│   │ │   (device config push)  │                     │ │   ├─ service.name       │    │
│   │ └─ InstanceUid            │                     │ │   ├─ device.count       │    │
│   │     (supervisor UUID)     │ ◄────────────────── │ │   ├─ device.id.X        │    │
│   └───────────────────────────┘                     │ │   ├─ device.status.X    │    │
│                                                     │ │   └─ device.config.X    │    │
│                                                     │ ├─ EffectiveConfig       │    │
│                                                     │ │   (current device cfg)  │    │
│                                                     │ └─ ComponentHealth       │    │
│                                                     │     (30s heartbeat)      │    │
│                                                     └───────────────────────────┘    │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### OpAMP Server: Function Block Diagram

The server implements OpAMP **server-side** callbacks to receive supervisor connections and push configs.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              OpAMP SERVER (main.go)                                  │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│   main()                                                                             │
│     │                                                                                │
│     ├──► NewOpAMPServer() ─────────────────────────────────────────────────────────┐│
│     │      Creates: agents map, devices map                                        ││
│     │                                                                              ││
│     ├──► server.New() ◄── opamp-go library                                         ││
│     │      │                                                                       ││
│     │      └──► server.Start(settings)                                             ││
│     │             │                                                                ││
│     │             ├──► OnConnecting() ─► Accept WebSocket connection               ││
│     │             │                                                                ││
│     │             ├──► OnConnected() ─► Log "New connection established"           ││
│     │             │                                                                ││
│     │             ├──► OnMessage(msg) ◄── AgentToServer from Supervisor            ││
│     │             │      │                                                         ││
│     │             │      ├─► Parse msg.InstanceUid → agentID                       ││
│     │             │      ├─► Check msg.AgentDescription.IdentifyingAttributes      ││
│     │             │      │     └─► service.name == "supervisor" → IsSupervisor     ││
│     │             │      ├─► Parse NonIdentifyingAttributes:                       ││
│     │             │      │     ├─► device.count → number of devices                ││
│     │             │      │     ├─► device.id.X → device IDs                        ││
│     │             │      │     ├─► device.status.X → config apply status           ││
│     │             │      │     └─► device.config.X → actual device config          ││
│     │             │      ├─► Update agents map, devices map                        ││
│     │             │      └─► Handle msg.EffectiveConfig → store device config      ││
│     │             │                                                                ││
│     │             └──► OnConnectionClose() ─► Remove agent + associated devices    ││
│     │                                                                              ││
│     └──► http.ListenAndServe(:4321) ───────────────────────────────────────────────┤│
│            │                                                                       ││
│            ├──► GET /                    → Serve dashboard.html                    ││
│            ├──► GET /api/devices         → GetDevices() → JSON list               ││
│            ├──► GET /api/devices/{id}    → GetDevice(id) → JSON                   ││
│            └──► POST /api/devices/config → PushConfig(deviceID, config)           ││
│                   │                                                                ││
│                   └──► Build ServerToAgent{RemoteConfig}                           ││
│                          └──► agent.conn.Send() ──► to Supervisor via WebSocket   ││
│                                                                                    ││
└────────────────────────────────────────────────────────────────────────────────────┘│
                                                                                      │
  Helper Functions:                                                                   │
  ┌────────────────────────┐  ┌────────────────────────┐  ┌────────────────────────┐  │
  │ getDefaultConfig()     │  │ getSilentConfig()      │  │ parsePipelinesFrom     │  │
  │ Returns FluentBit      │  │ Returns SERVICE-only   │  │ Config()               │  │
  │ config with INPUT/     │  │ config (no emission)   │  │ Extracts pipeline type │  │
  │ OUTPUT (emission ON)   │  │                        │  │ from config            │  │
  └────────────────────────┘  └────────────────────────┘  └────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### OpAMP Supervisor: Function Block Diagram

The supervisor implements OpAMP **client-side** callbacks to connect to the server and relay configs to devices.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                           OpAMP SUPERVISOR (main.go)                                 │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│   main()                                                                             │
│     │                                                                                │
│     ├──► NewPersistentRegistry(stateFile) ◄── runtime/persistence.go                │
│     │      │                                                                         │
│     │      ├──► loadState() ─► Load devices from JSON                               │
│     │      ├──► periodicStateSave() ─► Save every 30s                               │
│     │      └──► staleConnectionCleanup() ─► Mark stale after 2min                   │
│     │                                                                                │
│     ├──► NewRealOpAMPBridge(serverURL, ...) ◄── server/opamp_bridge.go              │
│     │      │                                                                         │
│     │      └──► bridge.Start(ctx)                                                    │
│     │             │                                                                  │
│     │             ├──► client.NewWebSocket() ◄── opamp-go library                    │
│     │             │                                                                  │
│     │             ├──► client.Start(settings)                                        │
│     │             │      │                                                           │
│     │             │      ├──► OnConnect() ─► Log "Connected to server"               │
│     │             │      │                                                           │
│     │             │      └──► OnMessage(msg) ◄── ServerToAgent from Server           │
│     │             │             │                                                    │
│     │             │             ├─► Parse msg.RemoteConfig.ConfigMap                 │
│     │             │             ├─► Extract deviceID (key) and config (value)        │
│     │             │             ├─► Build ConfigPush{DeviceId, ConfigData, Hash}     │
│     │             │             └─► enqueueConfig(deviceID, configPush)              │
│     │             │                                                                  │
│     │             ├──► periodicDeviceSync() (every 10s)                              │
│     │             │      └──► updateAgentDescription()                               │
│     │             │             └──► SetAgentDescription{                            │
│     │             │                    IdentifyingAttributes: service.name           │
│     │             │                    NonIdentifyingAttributes:                     │
│     │             │                      device.count, device.id.X,                  │
│     │             │                      device.status.X, device.config.X }          │
│     │             │                                                                  │
│     │             └──► periodicHealthReport() (every 30s)                            │
│     │                    └──► SetHealth{Healthy: true}                               │
│     │                                                                                │
│     ├──► NewControlService(registry, bridge) ◄── server/control.go                  │
│     │      │                                                                         │
│     │      └──► grpcServer.Serve(:50051)                                             │
│     │             │                                                                  │
│     │             └──► Control(stream) ◄── Bidirectional gRPC with Device-Agent      │
│     │                    │                                                           │
│     │                    ├─► Recv Register{NodeId, AgentType}                        │
│     │                    │     └─► registry.OnDeviceConnect(nodeID, stream)          │
│     │                    │                                                           │
│     │                    ├─► Command Pump (goroutine):                               │
│     │                    │     ├─► Read from cmdQueue → stream.Send(Command)         │
│     │                    │     └─► Read from configQueue → stream.Send(ConfigPush)   │
│     │                    │                                                           │
│     │                    └─► Receive Loop (goroutine):                               │
│     │                          ├─► Event → bridge.SendStatus()                       │
│     │                          └─► ConfigAck → bridge.OnConfigAck()                  │
│     │                                │                                               │
│     │                                └─► updateAgentDescription() to Server          │
│     │                                                                                │
│     └──► signal.Notify() ─► Graceful shutdown                                        │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### End-to-End Config Push Flow

This shows the complete journey of a config push from UI click to FluentBit hot reload:

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           CONFIG PUSH FLOW (End-to-End)                             │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ╔═══════════════╗                                                                  │
│  ║  1. USER UI   ║  Click "Apply Policies" or "Push Config"                        │
│  ╚═══════╤═══════╝                                                                  │
│          │ POST /api/devices/config {deviceId, config}                              │
│          ▼                                                                          │
│  ╔═══════════════════════════════════════════════════════════════════════╗          │
│  ║  2. OpAMP SERVER                                                      ║          │
│  ║     PushConfig(deviceID, config)                                      ║          │
│  ║       │                                                               ║          │
│  ║       ├─► Lookup device → get SupervisorID                            ║          │
│  ║       ├─► Lookup agent by SupervisorID                                ║          │
│  ║       ├─► Build: ServerToAgent{RemoteConfig{ConfigMap{deviceID:cfg}}} ║          │
│  ║       └─► agent.conn.Send() ────────────────────────────────────────┐ ║          │
│  ╚═════════════════════════════════════════════════════════════════════│═╝          │
│                                                                        │            │
│                                        OpAMP WebSocket (ServerToAgent) │            │
│                                                                        ▼            │
│  ╔═══════════════════════════════════════════════════════════════════════╗          │
│  ║  3. OpAMP SUPERVISOR (opamp_bridge.go)                                ║          │
│  ║     onMessage(msg)                                                    ║          │
│  ║       │                                                               ║          │
│  ║       ├─► Parse msg.RemoteConfig.Config.ConfigMap                     ║          │
│  ║       ├─► For each {deviceID: configFile}:                            ║          │
│  ║       │     └─► Build ConfigPush{DeviceId, ConfigData, ConfigHash}    ║          │
│  ║       └─► enqueueConfig(deviceID, configPush) ──────────────────────┐ ║          │
│  ╚═════════════════════════════════════════════════════════════════════│═╝          │
│                                                                        │            │
│                                              Internal configQueue      │            │
│                                                                        ▼            │
│  ╔═══════════════════════════════════════════════════════════════════════╗          │
│  ║  4. CONTROL SERVICE (control.go)                                      ║          │
│  ║     Command Pump goroutine                                            ║          │
│  ║       │                                                               ║          │
│  ║       ├─► Read ConfigPush from configQueue                            ║          │
│  ║       └─► stream.Send(Envelope{ConfigPush}) ────────────────────────┐ ║          │
│  ╚═════════════════════════════════════════════════════════════════════│═╝          │
│                                                                        │            │
│                                           gRPC Stream (to Device-Agent)│            │
│                                                                        ▼            │
│  ╔═══════════════════════════════════════════════════════════════════════╗          │
│  ║  5. DEVICE-AGENT (main.go)                                            ║          │
│  ║     handleConfigPush(cfg)                                             ║          │
│  ║       │                                                               ║          │
│  ║       ├─► Write config to /shared-config/fluent-bit.conf (PVC)        ║          │
│  ║       ├─► POST http://fluentbit-device-N:2020/api/v2/reload           ║          │
│  ║       └─► Send ConfigAck{Success: true, ConfigHash, EffectiveConfig}  ║          │
│  ╚═══════════════════════════════════════════════════════════════════════╝          │
│                            │                        │                               │
│                            │ Shared PVC             │ gRPC (ConfigAck)              │
│                            ▼                        ▼                               │
│  ╔═════════════════════════════════════╗    ╔════════════════════════════════════╗  │
│  ║  6. FLUENT BIT POD                  ║    ║  7. ACK PROPAGATION (reverse)      ║  │
│  ║     │                               ║    ║                                    ║  │
│  ║     ├─► Receive /api/v2/reload      ║    ║  Device-Agent                      ║  │
│  ║     ├─► Re-read fluent-bit.conf     ║    ║       │ ConfigAck                  ║  │
│  ║     └─► Apply new config            ║    ║       ▼                            ║  │
│  ║         (hot reload, no restart)    ║    ║  ControlService                    ║  │
│  ╚═════════════════════════════════════╝    ║       │ Envelope{ConfigAck}        ║  │
│                                             ║       ▼                            ║  │
│                                             ║  OpAMPBridge.OnConfigAck()         ║  │
│                                             ║       │ Update ackStatus map       ║  │
│                                             ║       ▼                            ║  │
│                                             ║  updateAgentDescription()          ║  │
│                                             ║       │ device.status.X = applied  ║  │
│                                             ║       ▼                            ║  │
│                                             ║  OpAMP SERVER                      ║  │
│                                             ║       └─► Update device.ConfigStatus  │
│                                             ╚════════════════════════════════════╝  │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

### 🎨 Dashboard UI Features

The dashboard provides a comprehensive interface for managing edge devices:

#### Device List (Left Sidebar)
- **Device cards** with status indicator (online/offline)
- **Emission badge** showing EMITTING or OFF status
- **🗑️ Delete button** on each device for targeted removal
- **➕ Deploy Test Device** button (POC Provisioner)
- **Search** to filter devices
- **Stats** showing total devices, online count, emitting count

#### Device Detail Panel (Right Side)
When a device is selected:

| Section | Description |
|---------|-------------|
| **Data Emission Toggle** | ON/OFF switch with lock indicator during updates |
| **Data Policies** | Throttle, Grep (log level), Modify (field removal) |
| **Config Preview** | Live preview of generated FluentBit config |
| **Push Custom Config** | Raw config textarea with pre-populated template |
| **Current Live Config** | Real-time display of device's actual config |

#### Policy Options

| Policy | Options | Description |
|--------|---------|-------------|
| **Throttle** | Rate: 1-1000, Window: 1-60s | Limit log throughput |
| **Grep** | Field + Levels (INFO/WARN/ERROR/DEBUG) | Filter logs by level |
| **Modify** | Fields (password, token, secret, etc.) | Remove sensitive fields |

#### Emission Behavior
- **New devices** start with emission **OFF** (silent config)
- **Toggle ON** → Pushes full config with INPUT/OUTPUT sections → ✅ Works
- **Toggle OFF** → Disabled in POC (see limitation below)
- **Push Custom Config** → Auto-enables emission

#### ⚠️ POC Limitation: Toggle OFF

Toggle OFF is **disabled** in this POC. The stock FluentBit image does not support `policy_type: block_all/allow_all` which is required for proper emission control.

**Why?** FluentBit's HTTP hot reload API hangs when transitioning from a config WITH plugins to a config WITHOUT plugins. In production, custom FluentBit images with `out_aruba_local` plugin and `policy_type` support enable seamless ON↔OFF toggling.

**Workaround for testing:** Remove and redeploy the device to reset it to OFF state.

---

### OpAMP Protocol Functions Used

This POC implements the following OpAMP specification functions:

| Function | Description |
|----------|-------------|
| [`AgentToServer`](https://opentelemetry.io/docs/specs/opamp/#agenttoserver-message) | Message sent from agent to server containing status, health, and capabilities |
| [`ServerToAgent`](https://opentelemetry.io/docs/specs/opamp/#servertoagent-message) | Response from server with remote config, commands, and connection settings |
| [`AgentDescription`](https://opentelemetry.io/docs/specs/opamp/#agentdescription-message) | Agent metadata including identifying and non-identifying attributes |
| [`EffectiveConfig`](https://opentelemetry.io/docs/specs/opamp/#effectiveconfig-message) | Current merged configuration the agent is using (remote + local) |
| [`RemoteConfigStatus`](https://opentelemetry.io/docs/specs/opamp/#remoteconfigstatus-message) | Status of remote config application (APPLIED, APPLYING, FAILED) |
| [`ComponentHealth`](https://opentelemetry.io/docs/specs/opamp/#componenthealth-message) | Health status of agent and sub-components with timestamps |
| [`AgentRemoteConfig`](https://opentelemetry.io/docs/specs/opamp/#agentremoteconfig-message) | Remote configuration offered by server with config hash |
| [`AgentCapabilities`](https://opentelemetry.io/docs/specs/opamp/#agenttoservercapabilities) | Bitmask of agent capabilities (AcceptsRemoteConfig, ReportsStatus, etc.) |
| [Status Reporting](https://opentelemetry.io/docs/specs/opamp/#status-reporting) | Continuous status updates from agent to server on state changes |
| [WebSocket Transport](https://opentelemetry.io/docs/specs/opamp/#websocket-transport) | Full-duplex async communication using WebSocket with Protobuf encoding |
| [Heartbeat](https://opentelemetry.io/docs/specs/opamp/#websocket-message-exchange) | Periodic AgentToServer messages (30s default) to maintain connection |



### Pod Separation Design in the Edge Device

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
git clone https://github.com/jayanta-kashyap/opamp-server.git opamp-server
git clone https://github.com/jayanta-kashyap/opamp-supervisor.git opamp-supervisor
git clone https://github.com/jayanta-kashyap/opamp-device-agent.git opamp-device-agent
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

After setup, access the UI at: **http://localhost:4321**

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
open http://localhost:4321
```

</details>

---

## 🎮 Using the System

### Deploy/Remove Devices via UI (POC Provisioner)

The POC Provisioner allows deploying and removing test devices directly from the dashboard - no kubectl needed!

1. Open http://localhost:4321
2. Click **"➕ Deploy Test Device"** to add a new device
3. Device auto-registers and appears in list within seconds
4. Click **"🗑️"** button on any device to remove it

**Note:** The POC Provisioner runs as a separate service in `opamp-control` namespace with its own port-forward on `:8090`.

### Apply Data Policies via UI

1. Select a device from the sidebar
2. Enable desired policies:
   - **Throttle**: Set rate (logs/sec) and window (seconds)
   - **Grep**: Select log levels to keep (INFO, WARN, ERROR, DEBUG)
   - **Modify**: Select sensitive fields to remove (password, token, secret, etc.)
3. Preview the generated config in the **Config Preview** section
4. Click **"Apply Policies"** to push the config
5. View the applied config in **"Current Live Config"**

### Push Custom FluentBit Config

1. Select a device
2. Scroll to **"Push Custom Config"** section
3. Template is pre-populated with a working FluentBit config
4. Modify as needed
5. Click **"Push Config"** → Config is applied and emission is auto-enabled

### View Devices via API
```bash
curl -s http://localhost:4321/api/devices | jq '.devices[] | {id, connected, emission_enabled}'
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

### Toggle Data Emission via UI
1. Open http://localhost:4321
2. Select a device from the sidebar
3. Click the **Data Emission** toggle
4. **Toggle ON** → Device starts emitting logs ✅
5. **Toggle OFF** → Shows POC limitation toast (disabled in POC)

> **Note:** To reset a device to OFF state, use the 🗑️ button to remove it, then redeploy via "➕ Deploy Test Device".

### Toggle Data Emission via API
```bash
# Enable emission (works)
curl -X POST http://localhost:4321/api/devices/config \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "device-1", "setEmission": true}'
```

> **Note:** `setEmission: false` is disabled in POC. See [POC Limitation](#️-poc-limitation-toggle-off) for details.

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
6. User clicks toggle to enable/disable emission
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

### Emission Toggle Design

**How does ON work?**

Fluent Bit's hot reload supports dynamic config changes without restart:

- **Toggle ON**: Pushes config with `[INPUT]` + `[OUTPUT]` → Data flows ✅
- **Hot Reload**: Works via Fluent Bit's `/api/v2/reload` API
- **Zero Downtime**: No pod restarts required

**Why is Toggle OFF disabled in POC?**

| Issue | Description |
|-------|-------------|
| HTTP Reload Hang | FluentBit HTTP reload API hangs when transitioning FROM config WITH plugins TO config WITHOUT plugins |
| SIGHUP Works | SIGHUP signal works reliably but requires shared process namespace (not standard K8s) |
| Production Solution | Custom FluentBit with `policy_type: block_all/allow_all` support enables seamless toggling |

**Production Architecture:**
```
# Emission ON (allow_all)
[OUTPUT]
    name         out_aruba_local
    policy_type  allow_all

# Emission OFF (block_all) 
[OUTPUT]
    name         out_aruba_local
    policy_type  block_all
```

This maintains the same plugin structure, allowing hot reload to work in both directions.

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
