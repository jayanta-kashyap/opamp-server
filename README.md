# OpAMP Server

## Overview
The OpAMP Server is the central management and monitoring hub for the entire POC. It provides a web-based UI for managing OpenTelemetry collectors deployed on edge devices and acts as the OpAMP protocol server that supervisors connect to.

## Role in the POC Architecture

```
┌─────────────────────────────────────────┐
│      OpAMP Server (This Component)      │
│  ┌─────────────┐      ┌──────────────┐ │
│  │   Web UI    │      │ OpAMP Server │ │
│  │  (Port 4321)│      │  (Port 4320) │ │
│  └─────────────┘      └──────────────┘ │
└─────────────────────────────────────────┘
              ↕ OpAMP Protocol (WebSocket)
┌─────────────────────────────────────────┐
│           Supervisor (gRPC)             │
└─────────────────────────────────────────┘
              ↕ Bidirectional gRPC
┌─────────────────────────────────────────┐
│     Device Agents + OTel Collectors     │
└─────────────────────────────────────────┘
```

## Components

### 1. Web UI (Port 4321)
**Purpose:** Provides a user-friendly interface for operators to manage OTel collectors on edge devices.

**Functionality:**
- **Device Discovery:** Automatically displays all connected OTel agents with their IDs and connection status
- **Configuration Management:** 
  - View current configuration of any device
  - Send new YAML configurations to devices
  - Load pre-built configuration templates
- **Real-time Status:** Shows online/offline status of each device
- **Success/Error Feedback:** Displays clear messages when configurations are pushed successfully or fail

**How it works:**
- Fetches device list from `/api/devices` endpoint every 5 seconds
- Allows clicking on a device to view its current config
- Provides input box to write/paste desired configuration
- Sends configuration to `/api/agents/config` endpoint
- Displays success ✅ or error ❌ messages

### 2. OpAMP Server (Port 4320)
**Purpose:** Implements the OpAMP (Open Agent Management Protocol) specification to manage remote agents.

**Functionality:**
- **Agent Registration:** Accepts connections from supervisors via WebSocket
- **Device Tracking:** Maintains state of all supervisors and their managed devices
- **Configuration Distribution:** Pushes configuration updates to specific devices via their supervisor
- **Status Collection:** Receives status updates and telemetry from devices through supervisors

**How it works:**
- Listens for OpAMP WebSocket connections on port 4320
- Uses OpAMP protocol callbacks to handle:
  - `OnConnecting`: Validates incoming connections
  - `OnConnected`: Registers new supervisors
  - `OnMessage`: Processes agent identification and status updates
  - `OnConnectionClose`: Handles disconnections
- Extracts device list from supervisor's non-identifying attributes
- Maps device IDs to their managing supervisor for config routing

## Data Flow

### Device Registration Flow
1. Supervisor connects to OpAMP Server via WebSocket
2. Supervisor sends AgentDescription with:
   - Identifying attributes (service.name = "supervisor")
   - Non-identifying attributes (device count + device IDs)
3. OpAMP Server registers supervisor and all its devices
4. UI automatically shows new devices

### Configuration Push Flow
1. Operator selects device in UI
2. Operator enters desired OTel collector config (YAML)
3. Operator clicks "Push Configuration"
4. UI sends POST to `/api/agents/config` with deviceId and config
5. OpAMP Server finds supervisor managing that device
6. OpAMP Server creates RemoteConfig message with device-specific config
7. OpAMP Server sends config to supervisor via OpAMP protocol
8. Supervisor forwards config to device via gRPC stream
9. Device agent applies config to its OTel collector
10. UI shows success message ✅

## API Endpoints

### GET /
Returns the dashboard HTML UI

### GET /api/agents
Returns list of all connected supervisors
```json
{
  "agents": [
    {
      "ID": "supervisor-001",
      "Name": "supervisor",
      "Connected": true,
      "IsSupervisor": true,
      "Devices": ["device-1", "device-2"]
    }
  ]
}
```

### GET /api/devices
Returns list of all OTel agents (devices)
```json
{
  "devices": [
    {
      "ID": "device-1",
      "Name": "device-1",
      "Connected": true,
      "Config": "...",
      "SupervisorID": "supervisor-001"
    }
  ]
}
```

### POST /api/agents/config
Pushes configuration to a specific device
```json
{
  "agentId": "device-1",
  "config": "receivers:\n  otlp:\n    ..."
}
```

## Key Features in POC

1. **Centralized Management:** Single UI to manage all edge devices
2. **Real-time Visibility:** Live connection status of all devices
3. **Configuration Simplicity:** YAML-based config with template support
4. **Error Handling:** Clear error messages for failed operations
5. **Scalability:** Can manage multiple supervisors, each managing multiple devices

## Technology Stack
- **Language:** Go
- **OpAMP Library:** github.com/open-telemetry/opamp-go
- **Web Framework:** Standard net/http
- **Protocol:** WebSocket (OpAMP), HTTP/REST (UI API)

## Deployment
- **Container Image:** `opamp-server:latest`
- **Kubernetes:** Deployed in `opamp-system` namespace
- **Ports:**
  - 4320: OpAMP WebSocket endpoint
  - 4321: Web UI and API

## Building
```bash
# Build binary
go build -o server ./cmd/server

# Build Docker image
docker build -t opamp-server:latest -f DockerFile .
```

## How This Enables E2E POC
The OpAMP Server is the **control plane** of the POC. It:
- Provides the **user interface** for operators
- Implements the **OpAMP standard** for agent management
- Acts as the **configuration source of truth**
- Enables **remote management** of edge devices
- Bridges **UI actions** to **device updates** seamlessly

Without this component, there would be no centralized way to manage configurations across distributed OTel collectors.
