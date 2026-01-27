## Scalable Device Configuration Management for 1M+ Devices

---

## Table of Contents

| Section | Description |
|---------|-------------|
| [1. Current POC Architecture](#1-current-poc-architecture) | Single-instance design in minikube |
| [2. Production Challenges](#2-production-challenges) | Why POC won't scale |
| [3. Proposed Production Architecture](#3-proposed-production-architecture) | High-level overview with Redis + Kafka |
| [4. Component Deep Dive](#4-component-deep-dive) | Server, Supervisor, Redis, Kafka details |
| [5. Data Flow Patterns](#5-data-flow-patterns) | Registration, commands, hot reload, DDS |
| [6. Technology Choices](#6-technology-choices) | Redis + Kafka recommendation |
| [7. Scaling Strategy](#7-scaling-strategy) | Capacity planning and sizing |
| [8. Implementation Roadmap](#8-implementation-roadmap) | Phased rollout plan |

**Quick Links:**
- [4.1 OpAMP Server](#41-opamp-server-stateless-api-layer) | [4.2 Supervisor Fleet](#42-supervisor-fleet-connection-managers) | [4.3 Redis](#43-rediselasticache-state-storage) | [4.4 Kafka](#44-kafka-message-bus)
- [5.1 Device Registration](#51-device-registration-flow) | [5.2 Command Flow](#52-command-flow-toggle-emission) | [5.3 Hot Reload](#53-hot-reload-flow-unchanged-from-poc) | [5.4 DDS Observability](#54-cloud-service-observability-serversupervisor--dds)

---

# Agenda

1. Current POC Architecture
2. Production Challenges
3. Proposed Production Architecture
4. Component Deep Dive
5. Data Flow Patterns
6. Technology Choices
7. Scaling Strategy
8. Implementation Roadmap

---

# 1. Current POC Architecture

## Single-Instance Design

```
┌─────────────────────────────────────────────────────────────┐
│                    Minikube Cluster                         │
├─────────────────────────────────────────────────────────────┤
│  opamp-control namespace                                    │
│  ┌────────────┐   OpAMP    ┌─────────────┐                 │
│  │   Server   │◄──────────►│ Supervisor  │                 │
│  │  (1 pod)   │  WebSocket │  (1 pod)    │                 │
│  │            │            │             │                 │
│  │ • REST API │            │ • gRPC      │                 │
│  │ • Dashboard│            │ • In-memory │                 │
│  │ • In-memory│            │   device map│                 │
│  └────────────┘            └──────┬──────┘                 │
│                                   │                         │
├───────────────────────────────────┼─────────────────────────┤
│  opamp-edge namespace             │ gRPC (50051)            │
│                                   ▼                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ Device      │  │ Device      │  │ Device      │         │
│  │ Agent 1     │  │ Agent 2     │  │ Agent N     │         │
│  │ + FluentBit │  │ + FluentBit │  │ + FluentBit │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

## POC Characteristics

| Aspect | Current State |
|--------|---------------|
| **Devices** | 1 device |
| **Server Pods** | 1 |
| **Supervisor Pods** | 1 |
| **State Storage** | In-memory |
| **Message Passing** | Direct WebSocket |

✅ **Works perfectly for POC and demo**

---

# 2. Production Challenges

## Why POC Architecture Won't Scale

### Problem 1: Single Point of Failure
```
Server Pod crashes → All UI/API gone
Supervisor Pod crashes → All 1M device connections lost
```

### Problem 2: Memory Limits
```
1M devices × 1KB state each = 1GB+ memory per pod
Single pod can't hold this
```

### Problem 3: Connection Limits
```
Each supervisor pod can handle ~20,000 gRPC connections
1M devices ÷ 20K = 50 supervisor pods minimum
```

### Problem 4: Stateless Scaling
```
Pod 1 receives "toggle device-5"
But device-5 is connected to Pod 37
How does Pod 1 know this? → Needs shared state
```

---

# 3. Proposed Production Architecture

## High-Level Overview

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                Aruba Cloud (Kubernetes)                                  │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  ┌───────────────────────────────────────────────────────────┐   ┌────────────────────┐  │
│  │                  Control Plane Services                    │   │ DDS (CNX Common    │  │
│  │                                                            │   │ Observability)     │  │
│  │  ┌────────────────────┐    ┌────────────────────┐         │   │                    │  │
│  │  │  Redis/Elasticache │    │       Kafka        │         │   │ ┌────────────────┐ │  │
│  │  │      (State)       │    │    (Messaging)     │         │   │ │ Grafana Loki   │ │  │
│  │  └─────────┬──────────┘    └─────────┬──────────┘         │   │ │   (Logs)       │ │  │
│  │            │                         │                    │   │ └────────────────┘ │  │
│  │            ▼                         ▼                    │   │ ┌────────────────┐ │  │
│  │  ┌────────────────────────────────────────────────────┐   │   │ │ Grafana Mimir  │ │  │
│  │  │              OpAMP Servers (n pods)             │───┼───┼►│  (Metrics)     │ │  │
│  │  │                                                    │   │   │ └────────────────┘ │  │
│  │  │  • REST API    • Dashboard    • OTel SDK           │   │   │ ┌────────────────┐ │  │
│  │  └────────────────────────┬───────────────────────────┘   │   │ │ Grafana Tempo  │ │  │
│  │                           │                               │   │ │  (Traces)      │ │  │
│  │                           ▼                               │   │ └────────────────┘ │  │
│  │  ┌────────────────────────────────────────────────────┐   │   │                    │  │
│  │  │            Supervisor Fleet (m pods)             │───┼───┼►   (OTLP export)   │  │
│  │  │                                                    │   │   │                    │  │
│  │  │  ┌────┐ ┌────┐ ┌────┐ ┌────┐    • OTel SDK        │   │   └────────────────────┘  │
│  │  │  │S-1 │ │S-2 │ │S-3 │ │S-50│   (20K devices each) │   │                           │
│  │  │  └────┘ └────┘ └────┘ └────┘                       │   │                           │
│  │  └────────────────────────┬───────────────────────────┘   │                           │
│  │                           │                               │                           │
│  └───────────────────────────┼───────────────────────────────┘                           │
│                              │                                                           │
│                              │ gRPC (bidirectional stream)                               │
│                              ▼                                                           │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐   │
│  │                          Edge / Campus / Devices                                   │   │
│  │                                                                                    │   │
│  │    ┌─────┐   ┌─────┐   ┌─────┐   ┌─────┐              ┌─────────────┐             │   │
│  │    │ AP  │   │ AP  │   │ SW  │   │ GW  │    ...       │ 1M+ Devices │             │   │
│  │    └─────┘   └─────┘   └─────┘   └─────┘              └─────────────┘             │   │
│  └───────────────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

# 4. Component Deep Dive

## 4.1 OpAMP Server (Stateless API Layer)

**Responsibilities:**
- REST API endpoints
- Web Dashboard
- Authenticate requests
- Route commands to correct supervisor via Kafka

**Scaling:**
- 3-10 pods behind load balancer
- Horizontally scalable
- No local state (reads from Redis)

```go
// Pseudo-code: Handle toggle command
func HandleToggle(deviceID string, state bool) {
    // 1. Lookup which supervisor owns this device
    supervisor := db.Query("SELECT supervisor_id FROM devices WHERE device_id = ?", deviceID)
    
    // 2. Publish command to Kafka
    kafka.Produce("opamp.commands", supervisor, Command{
        DeviceID: deviceID,
        Action:   "toggle",
        State:    state,
    })
}
```

---

## 4.2 Supervisor Fleet (Connection Managers)

**Responsibilities:**
- Maintain gRPC streams to devices
- Execute commands received from Kafka
- Report device status to Redis
- Handle config delivery and hot reload

**Scaling:**
- ~50 pods for 1M devices
- Each pod handles ~20K connections
- Stateful (holds connections in memory)

```go
// Pseudo-code: Supervisor startup
func StartSupervisor(supervisorID string) {
    // 1. Subscribe to commands for this supervisor
    kafka.Subscribe("opamp.commands", supervisorID)
    
    // 2. Accept device connections
    grpcServer.Serve(":50051")
    
    // 3. On device connect, register in Redis
    onDeviceConnect(device) {
        redis.Set("device:"+device.ID+":supervisor", supervisorID)
        redis.Expire("device:"+device.ID+":supervisor", 300) // 5min TTL
        redis.SAdd("supervisor:"+supervisorID+":devices", device.ID)
    }
}
```

---

## 4.3 Redis/Elasticache (State Storage)

**The Only Database OpAMP Needs**

Redis serves as the sole data store for OpAMP. No SQL database required.

### Why Redis Only?

| Requirement | Redis Solution | Why Not SQL? |
|-------------|----------------|---------------|
| Device→Supervisor lookup | `GET device:X:supervisor` (0.5ms) | SQL is 10-20x slower |
| Device status | `HSET device:X status online` | Key-value is simpler |
| Config cache | `SET config:fluentbit:v1 <data>` | No schema needed |
| Auto-cleanup | `EXPIRE device:X:supervisor 300` | Built-in TTL |

### Complete Redis Data Model

```redis
# =====================================================
# DEVICE ROUTING (Critical Path - Every Command)
# =====================================================

# Which supervisor has this device? (THE most important key)
SET device:device-5:supervisor "supervisor-pod-3"
EXPIRE device:device-5:supervisor 300  # 5min TTL, auto-cleanup on disconnect

# =====================================================
# DEVICE STATUS (For Dashboard)
# =====================================================

# Device details as a hash
HSET device:device-5 \
    status "online" \
    emission "true" \
    config_version "v1.2.3" \
    agent_type "fluentbit" \
    last_seen "1706356800" \
    connected_at "1706350000"

# All online devices (for quick listing)
SADD devices:online "device-5" "device-6" "device-7"

# =====================================================
# SUPERVISOR TRACKING (For Load Balancing)
# =====================================================

# Which devices are on each supervisor?
SADD supervisor:supervisor-pod-3:devices "device-5" "device-100" "device-500"

# How many devices per supervisor? (for new connection routing)
INCR supervisor:supervisor-pod-3:device_count

# =====================================================
# CONFIG CACHE (Rarely Changes)
# =====================================================

# Config templates by type and version
SET config:fluentbit:v1.2.3 "[SERVICE]\n    hot_reload On\n..."
SET config:fluentbit:latest "v1.2.3"  # Pointer to current version
```

### Memory Calculation

```
1M devices:
├── device:X:supervisor (1M keys × 50 bytes) = 50 MB
├── device:X hash (1M keys × 100 bytes)     = 100 MB
├── supervisor sets (50 sets × 20K members)  = 10 MB
└── config cache                             = 1 MB
                                              --------
                                     Total:   ~160 MB

Elasticache: Even smallest instance (cache.t3.micro = 0.5 GB) handles this easily.
Recommended: cache.r6g.large (13 GB) for headroom and replication.
```

---

## 4.4 Kafka (Message Bus)

**Topics:**

| Topic | Purpose | Key | Consumers |
|-------|---------|-----|-----------|
| `opamp.commands` | Server → Supervisor commands | supervisor_id | Supervisor pods |
| `opamp.events` | Device → Server events (optional) | device_id | Server pods |
| `opamp.config-updates` | Broadcast config changes | - | All supervisors |

**Why Kafka:**
- ✅ Already available in CNX
- ✅ Durable (commands not lost)
- ✅ Ordered delivery per partition
- ✅ Replay capability for recovery
- ✅ Scales to millions of messages/sec

---

# 5. Data Flow Patterns

## 5.1 Device Registration Flow

```
┌────────────┐     ┌─────────────┐     ┌────────────┐
│   Device   │     │ Supervisor  │     │   Redis    │
│ (device-5) │     │   Pod 3     │     │            │
└────────────┘     └─────────────┘     └────────────┘
      │                   │                  │
      │ 1. gRPC Connect   │                  │
      │──────────────────►│                  │
      │                   │                  │
      │                   │ 2. SET device:   │
      │                   │    device-5:sup  │
      │                   │─────────────────►│
      │                   │    (0.5ms)       │
      │                   │                  │
      │ 3. Connection ACK │                  │
      │◄──────────────────│                  │
      │                   │                  │
```

---

## 5.2 Command Flow (Toggle Emission)

```
┌──────┐    ┌────────┐    ┌──────────┐    ┌───────┐    ┌────────────┐    ┌────────┐
│ User │    │ Server │    │  Redis   │    │ Kafka │    │ Supervisor │    │ Device │
│      │    │ Pod 2  │    │          │    │       │    │   Pod 3    │    │device-5│
└──┬───┘    └───┬────┘    └────┬─────┘    └───┬───┘    └─────┬──────┘    └───┬────┘
   │            │              │              │              │               │
   │ 1. Toggle  │              │              │              │               │
   │ device-5   │              │              │              │               │
   │───────────►│              │              │              │               │
   │            │              │              │              │               │
   │            │ 2. GET device│              │              │               │
   │            │  :device-5:  │              │              │               │
   │            │  supervisor  │              │              │               │
   │            │─────────────►│              │              │               │
   │            │   (0.5ms!)   │              │              │               │
   │            │              │              │              │               │
   │            │ 3. "pod-3"   │              │              │               │
   │            │◄─────────────│              │              │               │
   │            │              │              │              │               │
   │            │ 4. Produce command          │              │               │
   │            │    to topic:pod-3           │              │               │
   │            │────────────────────────────►│              │               │
   │            │              │              │              │               │
   │            │              │              │ 5. Consume   │               │
   │            │              │              │─────────────►│               │
   │            │              │              │              │               │
   │            │              │              │              │ 6. gRPC       │
   │            │              │              │              │ ConfigPush    │
   │            │              │              │              │──────────────►│
   │            │              │              │              │               │
   │            │              │              │              │ 7. ConfigAck  │
   │            │              │              │              │◄──────────────│
   │            │              │              │              │               │
   │            │              │ 8. HSET      │              │               │
   │            │              │  emission=on │◄─────────────│               │
   │            │              │              │              │               │
   │ 9. Success │              │              │              │               │
   │◄───────────│              │              │              │               │
```

**Key Point:** Step 2-3 (Redis lookup) takes **0.5ms** vs 5-10ms if we used SQL.

---

## 5.3 Hot Reload Flow (Unchanged from POC)

```
Device Agent                     FluentBit Container
     │                                   │
     │ 1. Receive ConfigPush             │
     │    (new fluent-bit.conf)          │
     │                                   │
     │ 2. Write to /shared-config/       │
     │    fluent-bit.conf                │
     │                                   │
     │ 3. POST /api/v2/reload ──────────►│
     │                                   │
     │                    4. Re-read config
     │                    5. Apply new pipeline
     │                                   │
     │ 6. {"status": 0} ◄────────────────│
     │                                   │
     │ 7. Send ConfigAck                 │
     │    (success=true)                 │
```

**No restart required** - FluentBit hot reload preserves:
- Log position
- Buffer state
- Active connections

---

## 5.4 Cloud Service Observability (Server/Supervisor → DDS)

**Note:** This section describes observability for the OpAMP cloud services themselves (Server and Supervisor). This is separate from the edge device telemetry pipeline described in Section 5.3.

DDS is the **CNX observability platform**. The OpAMP cloud services (Server and Supervisor Go applications) are instrumented with OpenTelemetry SDK to send their telemetry to DDS, just like other CNX services.

### Key Design Principles

1. **No STDOUT/STDERR Logging** - Server and Supervisor code will NOT write logs to stdout/stderr. This ensures we do not accidentally send logs to Humio (which captures container stdout in CNX). All logging is done via OTel SDK exporters directly to DDS.

2. **OTel Exporters Only** - All three telemetry types (logs, metrics, traces) are sent exclusively via OTel OTLP exporters to DDS backends.

3. **Correlated Telemetry** - All three data types share trace context (trace_id, span_id), enabling seamless navigation in Grafana:
   - Jump from a log entry → related trace
   - Jump from a trace span → related logs
   - Jump from metrics → exemplars → traces
   - Full request lifecycle visibility across services

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         OpAMP Cloud Services                                │
│                                                                             │
│   ┌─────────────────────┐         ┌─────────────────────┐                  │
│   │    OpAMP Server     │         │     Supervisor      │                  │
│   │     (3-10 pods)     │         │     (50+ pods)      │                  │
│   │                     │         │                     │                  │
│   │  ┌───────────────┐  │         │  ┌───────────────┐  │                  │
│   │  │ OTel SDK      │  │         │  │ OTel SDK      │  │                  │
│   │  │ - Traces      │──┼─────────┼──│ - Traces      │  │                  │
│   │  │ - Metrics     │  │ shared  │  │ - Metrics     │  │                  │
│   │  │ - Logs        │  │ context │  │ - Logs        │  │                  │
│   │  └───────┬───────┘  │         │  └───────┬───────┘  │                  │
│   │          │          │         │          │          │                  │
│   │  ❌ No STDOUT       │         │  ❌ No STDOUT       │                  │
│   └──────────┼──────────┘         └──────────┼──────────┘                  │
│              │                               │                              │
│              └───────────────┬───────────────┘                              │
│                              │                                              │
│                              ▼  OTLP (gRPC/HTTP)                            │
│              ┌───────────────────────────────┐                              │
│              │      OTel Collector           │  (optional, or direct)       │
│              │      (sidecar or central)     │                              │
│              └───────────────┬───────────────┘                              │
│                              │                                              │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                  DDS (CNX Common Observability Platform)                     │
│                                                                              │
│    ┌────────────────┐    ┌────────────────┐    ┌────────────────┐           │
│    │  Grafana Loki  │◄───│───── trace_id ─────►│ Grafana Tempo  │           │
│    │    (Logs)      │    │                │    │   (Traces)     │           │
│    └───────▲────────┘    │   Correlated   │    └───────▲────────┘           │
│            │             │   via OTel     │            │                    │
│            └─────────────┤   Context      ├────────────┘                    │
│                          │                │                                  │
│                    ┌─────▼────────┐       │                                  │
│                    │Grafana Mimir │───────┘                                  │
│                    │  (Metrics)   │  exemplars → traces                      │
│                    └──────────────┘                                          │
│                                                                              │
│                        ┌────────────────────┐                                │
│                        │      Grafana       │                                │
│                        │   (Dashboards)     │                                │
│                        │  Logs ↔ Traces ↔   │                                │
│                        │      Metrics       │                                │
│                        └────────────────────┘                                │
└──────────────────────────────────────────────────────────────────────────────┘
```

### What Gets Instrumented

| Service | Telemetry Type | What It Captures |
|---------|----------------|------------------|
| **OpAMP Server** | Traces | API request latency, Redis/Kafka calls |
| **OpAMP Server** | Metrics | Request count, error rate, queue depth |
| **OpAMP Server** | Logs | Structured logs (JSON) |
| **Supervisor** | Traces | Device connection lifecycle, config push latency |
| **Supervisor** | Metrics | Connected devices, commands processed, errors |
| **Supervisor** | Logs | Device events, config changes |

### Go OTel Instrumentation Example

```go
import (
    "context"
    
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
    "go.opentelemetry.io/otel/log"
    "go.opentelemetry.io/otel/sdk/trace"
    sdklog "go.opentelemetry.io/otel/sdk/log"
)

var logger log.Logger

func initTelemetry(ctx context.Context) {
    // Trace exporter → Tempo
    traceExp, _ := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint("tempo.dds.aruba.cloud:4317"),
    )
    tp := trace.NewTracerProvider(trace.WithBatcher(traceExp))
    otel.SetTracerProvider(tp)
    
    // Log exporter → Loki (via OTel Collector)
    // NO STDOUT - logs go directly to DDS
    logExp, _ := otlploggrpc.New(ctx,
        otlploggrpc.WithEndpoint("loki.dds.aruba.cloud:4317"),
    )
    lp := sdklog.NewLoggerProvider(sdklog.WithProcessor(
        sdklog.NewBatchProcessor(logExp),
    ))
    logger = lp.Logger("opamp-server")
}

// Usage in handler - trace context automatically correlates logs
func HandleToggle(ctx context.Context, deviceID string) {
    ctx, span := otel.Tracer("opamp-server").Start(ctx, "HandleToggle")
    defer span.End()
    
    span.SetAttributes(attribute.String("device.id", deviceID))
    
    // ❌ NEVER: fmt.Println() or log.Printf() - goes to stdout/Humio
    // ✅ ALWAYS: OTel logger - goes to DDS with trace correlation
    logger.Emit(ctx, log.Record{
        Severity: log.SeverityInfo,
        Body:     log.StringValue("Processing toggle command"),
        Attributes: []log.KeyValue{
            log.String("device.id", deviceID),
        },
    })
    
    // ... business logic
}
```

### Key Metrics to Expose

| Metric | Type | Labels |
|--------|------|--------|
| `opamp_commands_total` | Counter | action, status |
| `opamp_config_push_duration_seconds` | Histogram | device_type |
| `opamp_connected_devices` | Gauge | supervisor_pod |
| `opamp_redis_latency_seconds` | Histogram | operation |
| `opamp_kafka_messages_total` | Counter | topic, status |

---

# 6. Technology Choices

## Recommendation: Redis + Kafka

After analyzing the available infrastructure in Aruba, we recommend using **only Redis and Kafka** for OpAMP.

### What OpAMP Actually Needs

| Operation | Frequency | Latency Need | Data Pattern |
|-----------|-----------|--------------|---------------|
| **"Which supervisor has device-X?"** | Every command | < 5ms | Key-value lookup |
| Device status updates | Every heartbeat | < 10ms | Key-value write |
| Config cache | On change | Not critical | Key-value |
| Command delivery | Every action | < 100ms | Pub/sub |

### Why Redis?

```
OpAMP Core Question: "Which supervisor has device-5?"

┌─────────────────┐
│      Redis      │  GET device:device-5:supervisor
│    0.5 ms ✅    │  → "supervisor-pod-3"
└─────────────────┘

✅ Sub-millisecond lookups (critical for 1M+ devices)
✅ Built-in TTL (auto-cleanup when devices disconnect)
✅ Simple key-value model (exactly what we need)
✅ Already available in Aruba (Elasticache)
✅ Trivial memory footprint (~200MB for 1M devices)
```

### Redis Data Model (Complete)

```redis
# Core routing - THE critical path (every command uses this)
SET device:device-5:supervisor "supervisor-pod-3"
EXPIRE device:device-5:supervisor 300  # Auto-cleanup on disconnect

# Device status (for dashboard)
HSET device:device-5 status "online" emission "true" config_version "v1.2.3"

# Supervisor tracking (for load balancing new connections)
INCR supervisor:supervisor-pod-3:device_count
SADD supervisor:supervisor-pod-3:devices "device-5"

# Config templates (cached, rarely changes)
SET config:fluentbit:v1.2.3 "<config data>"
```

**Total Redis memory for 1M devices: ~100-200 MB** (trivial)

### Why Kafka (Not Direct Calls)

| Without Kafka | With Kafka |
|---------------|------------|
| Server must know all supervisor IPs | Server publishes to topic |
| If supervisor down, command lost | Command persisted, delivered when supervisor recovers |
| Tight coupling | Loose coupling |
| No audit trail | Kafka retention = command history |

### Summary: What OpAMP Uses

| Component | Purpose |
|-----------|--------|
| **Redis/Elasticache** | Device→Supervisor routing, status cache, config templates |
| **Kafka** | Command delivery, durability, audit trail |
| **DDS** | Observability platform for cloud services (Server, Supervisor) telemetry |

### DDS Integration (Cloud Services Observability)

| DDS Component | Signal | Source | Use Case |
|---------------|--------|--------|----------|
| **Grafana Loki** | Logs | Server + Supervisor pods | Structured logs, error tracking |
| **Grafana Mimir** | Metrics | Server + Supervisor pods | Request rates, latency, device counts |
| **Grafana Tempo** | Traces | Server + Supervisor pods | Request tracing, end-to-end latency |

> **Note:** Other Aruba databases (CockroachDB, ArangoDB, ClickHouse) are not needed for OpAMP core functionality. They can be added later if analytics or audit log queries are required.

## Existing Infrastructure Leverage

```
┌─────────────────────────────────────────┐
│      Used for OpAMP (Already Have)      │
├─────────────────────────────────────────┤
│  ✅ Redis/Elasticache (state + routing) │
│  ✅ Kafka (command delivery)            │
│  ✅ DDS (Loki, Mimir, Tempo)            │
│  ✅ Kubernetes                          │
│  ✅ Load balancers                      │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│   Available but NOT Needed for OpAMP    │
├─────────────────────────────────────────┤
│  ⏸️  CockroachDB (keep for other uses)   │
│  ⏸️  ArangoDB (keep for other uses)      │
│  ⏸️  ClickHouse (keep for other uses)    │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│          New Components                  │
├─────────────────────────────────────────┤
│  🆕 OpAMP Server pods (OTel instrumented)|
│  🆕 Supervisor pods (OTel instrumented) │
│  🆕 Device agents (on each device)      │
└─────────────────────────────────────────┘
```

## The Simple Truth

```
OpAMP needs to answer ONE question fast:
"Which supervisor has device-X?"

Redis: 0.5ms
Everything else: Slower or wrong tool.

OpAMP needs to deliver commands reliably:
Kafka: Durable, ordered, already available.

That's it. Keep it simple.
```

---

# 7. Scaling Strategy

## Capacity Planning

| Scale | Devices | Supervisors | Servers | Kafka Partitions |
|-------|---------|-------------|---------|------------------|
| Small | 10K | 1 | 2 | 4 |
| Medium | 100K | 5 | 3 | 16 |
| Large | 500K | 25 | 5 | 32 |
| Enterprise | 1M+ | 50+ | 10 | 64 |

## Supervisor Pod Sizing

```
Each Supervisor Pod:
├── Memory: 2-4 GB
│   ├── 20K connections × 50KB each = 1GB
│   └── Overhead, buffers = 1-3GB
├── CPU: 2-4 cores
│   └── gRPC handling, config processing
└── Network: 1 Gbps
    └── Config pushes, heartbeats
```

## Redis Sizing

```
For 1M devices:
├── Keys: ~3M (device routing + status + configs)
├── Average value size: ~50 bytes
├── Total memory: ~150-200 MB
├── Elasticache node: cache.r6g.large (plenty of headroom)
└── Replication: 1 primary + 1 replica for HA
```

---

# 8. Implementation Roadmap

## Phase 1: POC Enhancement (Current)
- [x] Single server, single supervisor
- [x] 1 device working
- [x] Hot reload with FluentBit API
- [x] Dashboard with toggle controls

## Phase 2: Add Shared State (2-3 weeks)
- [x] Redis/Elasticache *(already available in CNX cluster)*
- [x] Kafka *(already available in CNX cluster)*
- [ ] Migrate device registry to Redis
- [ ] Add Kafka producer to Server
- [ ] Add Kafka consumer to Supervisor
- [ ] Add OTel instrumentation (no stdout, export to DDS)

## Phase 3: Multi-Pod Deployment (2-3 weeks)
- [ ] Scale Server to 3 replicas
- [ ] Scale Supervisor to 5 replicas
- [ ] Test failover scenarios
- [ ] Load test with 1000 devices

## Phase 4: Production Hardening (4-6 weeks)
- [ ] Add authentication/authorization
- [ ] Implement rate limiting
- [ ] Add comprehensive monitoring (DDS dashboards)
- [ ] Runbook and documentation
- [ ] Security audit

## Phase 5: Scale to 1M (Ongoing)
- [ ] Gradual rollout to production devices
- [ ] Performance tuning
- [ ] Capacity expansion as needed

---

# Summary

## Architecture Benefits

| Benefit | How Achieved |
|---------|--------------|
| **High Availability** | Multiple Server & Supervisor pods |
| **Horizontal Scale** | Stateless servers, partitioned supervisors |
| **Durability** | Redis for state, Kafka for commands |
| **Low Latency** | gRPC streaming, Redis lookups (0.5ms) |
| **Auditability** | All commands logged to Kafka (retention) |
| **Observability** | Cloud services (Server/Supervisor) instrumented with OTel → DDS |
| **Operational Simplicity** | Uses existing Redis + Kafka + DDS infrastructure |

## Key Metrics to Monitor

| Metric | Target |
|--------|--------|
| Config push latency | < 1 second |
| Hot reload success rate | > 99.9% |
| Device connection uptime | > 99.95% |
| Command delivery latency | < 500ms |

---

# Questions?

## Contact

- **POC Repository**: opamp-server, opamp-supervisor, opamp-device-agent
- **Minikube Profile**: control-plane
- **Namespaces**: opamp-control, opamp-edge

---

# Appendix A: Protocol Details

## OpAMP (Server ↔ Supervisor)

```
Protocol: WebSocket
Port: 4320
Library: open-telemetry/opamp-go
Direction: Bidirectional
Messages: AgentToServer, ServerToAgent
```

## Custom gRPC (Supervisor ↔ Device)

```protobuf
service ControlService {
  rpc Control(stream Envelope) returns (stream Envelope);
}

message Envelope {
  oneof body {
    EdgeIdentity register = 1;
    Command command = 2;
    Event event = 3;
    ConfigPush config_push = 4;
    ConfigAck config_ack = 5;
  }
}
```

---

# Appendix B: Kafka Topic Configuration

```yaml
# opamp.commands topic
Topic: opamp.commands
Partitions: 64 (one per supervisor or hash-based)
Replication: 3
Retention: 7 days
Key: supervisor_id
Value: JSON command payload

# Message format
{
  "device_id": "device-5",
  "command": "toggle_emission",
  "payload": {
    "state": true,
    "config_version": "v1.2.3"
  },
  "timestamp": "2026-01-27T10:30:00Z",
  "correlation_id": "uuid-here"
}
```

---

# Appendix C: Database Schema (Complete)

```sql
-- Core Tables
CREATE TABLE device_registry (
    device_id         VARCHAR(64) PRIMARY KEY,
    supervisor_id     VARCHAR(64) NOT NULL,
    agent_type        VARCHAR(32) DEFAULT 'fluentbit',
    platform          VARCHAR(32),
    version           VARCHAR(32),
    connected_at      TIMESTAMP DEFAULT NOW(),
    last_seen         TIMESTAMP DEFAULT NOW(),
    config_version    VARCHAR(64),
    effective_config  TEXT,
    emission_state    BOOLEAN DEFAULT false,
    
    INDEX idx_supervisor (supervisor_id),
    INDEX idx_agent_type (agent_type),
    INDEX idx_last_seen (last_seen)
);

CREATE TABLE config_templates (
    template_id       VARCHAR(64) PRIMARY KEY,
    name              VARCHAR(128),
    agent_type        VARCHAR(32),
    version           VARCHAR(32),
    config_data       TEXT NOT NULL,
    is_active         BOOLEAN DEFAULT true,
    created_by        VARCHAR(64),
    created_at        TIMESTAMP DEFAULT NOW(),
    updated_at        TIMESTAMP DEFAULT NOW()
);

CREATE TABLE command_audit (
    id                BIGSERIAL PRIMARY KEY,
    device_id         VARCHAR(64),
    supervisor_id     VARCHAR(64),
    command_type      VARCHAR(32),
    payload           JSONB,
    correlation_id    VARCHAR(64),
    status            VARCHAR(16),
    error_message     TEXT,
    initiated_by      VARCHAR(64),
    created_at        TIMESTAMP DEFAULT NOW(),
    completed_at      TIMESTAMP,
    
    INDEX idx_device_id (device_id),
    INDEX idx_created_at (created_at)
);

CREATE TABLE supervisor_registry (
    supervisor_id     VARCHAR(64) PRIMARY KEY,
    pod_name          VARCHAR(128),
    pod_ip            VARCHAR(45),
    device_count      INTEGER DEFAULT 0,
    capacity          INTEGER DEFAULT 20000,
    last_heartbeat    TIMESTAMP DEFAULT NOW(),
    status            VARCHAR(16) DEFAULT 'active',
    
    INDEX idx_status (status)
);
```
