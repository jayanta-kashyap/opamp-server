package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/open-telemetry/opamp-go/protobufs"
	"github.com/open-telemetry/opamp-go/server"
	"github.com/open-telemetry/opamp-go/server/types"
)

var dashboardHTML string

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

type Agent struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Connected    bool     `json:"connected"`
	Config       string   `json:"config"`
	IsSupervisor bool     `json:"is_supervisor"`
	Devices      []string `json:"devices,omitempty"`
	conn         types.Connection
	mu           sync.RWMutex
}

type Device struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Connected    bool   `json:"connected"`
	Config       string `json:"config"`
	SupervisorID string `json:"supervisor_id"`
}

type OpAMPServer struct {
	server  server.OpAMPServer
	agents  map[string]*Agent
	devices map[string]*Device // Individual devices from supervisors
	mu      sync.RWMutex
}

func NewOpAMPServer() *OpAMPServer {
	return &OpAMPServer{
		agents:  make(map[string]*Agent),
		devices: make(map[string]*Device),
	}
}

func (s *OpAMPServer) OnConnected(ctx context.Context, conn types.Connection) {
	log.Printf("New connection established")
}

func (s *OpAMPServer) OnMessage(ctx context.Context, conn types.Connection, msg *protobufs.AgentToServer) *protobufs.ServerToAgent {
	agentID := ""
	if msg.InstanceUid != nil {
		agentID = uuid.Must(uuid.FromBytes(msg.InstanceUid)).String()
	}

	log.Printf("Received message from agent: %s", agentID)

	s.mu.Lock()
	agent, exists := s.agents[agentID]
	if !exists {
		agentName := "Unknown"
		isSupervisor := false

		if msg.AgentDescription != nil && msg.AgentDescription.IdentifyingAttributes != nil {
			for _, attr := range msg.AgentDescription.IdentifyingAttributes {
				if attr.Key == "service.name" {
					agentName = attr.Value.GetStringValue()
					if agentName == "supervisor" {
						isSupervisor = true
					}
					break
				}
			}
		}

		agent = &Agent{
			ID:           agentID,
			Name:         agentName,
			Connected:    true,
			IsSupervisor: isSupervisor,
			conn:         conn,
			Devices:      []string{},
		}
		s.agents[agentID] = agent
		log.Printf("Registered new agent: %s (%s), supervisor=%v", agentID, agentName, isSupervisor)
	} else {
		agent.Connected = true
		agent.conn = conn
	}

	// Handle EffectiveConfig - store the current running config from devices
	if msg.EffectiveConfig != nil && msg.EffectiveConfig.ConfigMap != nil {
		for deviceID, configFile := range msg.EffectiveConfig.ConfigMap.ConfigMap {
			if device, exists := s.devices[deviceID]; exists {
				device.Config = string(configFile.Body)
				log.Printf("Updated effective config for device %s (%d bytes)", deviceID, len(configFile.Body))
			}
		}
	}

	// If this is a supervisor, extract device list from non-identifying attributes
	if agent.IsSupervisor && msg.AgentDescription != nil && msg.AgentDescription.NonIdentifyingAttributes != nil {
		deviceList := []string{}
		deviceCount := 0

		for _, attr := range msg.AgentDescription.NonIdentifyingAttributes {
			if attr.Key == "device.count" {
				deviceCount = int(attr.Value.GetIntValue())
			} else if len(attr.Key) > 7 && attr.Key[:7] == "device." {
				deviceID := attr.Value.GetStringValue()
				deviceList = append(deviceList, deviceID)

				// Create or update device entry
				device, devExists := s.devices[deviceID]
				if !devExists {
					device = &Device{
						ID:           deviceID,
						Name:         deviceID,
						Connected:    true,
						SupervisorID: agentID,
						Config:       getDefaultConfig(deviceID), // Load default config
					}
					s.devices[deviceID] = device
					log.Printf("Registered new device: %s via supervisor %s with default config", deviceID, agentID)
				} else {
					device.Connected = true
					device.SupervisorID = agentID
				}
			}
		}

		agent.Devices = deviceList
		log.Printf("Supervisor %s reports %d devices: %v", agentID, deviceCount, deviceList)

		// Mark devices not in current list as disconnected
		for devID, dev := range s.devices {
			if dev.SupervisorID == agentID {
				found := false
				for _, id := range deviceList {
					if id == devID {
						found = true
						break
					}
				}
				if !found {
					dev.Connected = false
					log.Printf("Device %s disconnected from supervisor %s", devID, agentID)
				}
			}
		}
	}

	s.mu.Unlock()

	// Return empty response for now
	return &protobufs.ServerToAgent{
		InstanceUid: msg.InstanceUid,
	}
}

func (s *OpAMPServer) OnConnectionClose(conn types.Connection) {
	log.Printf("Connection closed")

	s.mu.Lock()
	for id, agent := range s.agents {
		if agent.conn == conn {
			agent.Connected = false
			log.Printf("Agent %s disconnected", id)
			break
		}
	}
	s.mu.Unlock()
}

func (s *OpAMPServer) GetAgents() []Agent {
	s.mu.RLock()
	defer s.mu.RUnlock()

	agents := make([]Agent, 0, len(s.agents))
	for _, agent := range s.agents {
		agent.mu.RLock()
		agents = append(agents, Agent{
			ID:           agent.ID,
			Name:         agent.Name,
			Connected:    agent.Connected,
			Config:       agent.Config,
			IsSupervisor: agent.IsSupervisor,
			Devices:      agent.Devices,
		})
		agent.mu.RUnlock()
	}
	return agents
}

func (s *OpAMPServer) GetDevices() []Device {
	s.mu.RLock()
	defer s.mu.RUnlock()

	devices := make([]Device, 0, len(s.devices))
	for _, device := range s.devices {
		devices = append(devices, Device{
			ID:           device.ID,
			Name:         device.Name,
			Connected:    device.Connected,
			Config:       device.Config,
			SupervisorID: device.SupervisorID,
		})
	}
	return devices
}

func (s *OpAMPServer) GetDevice(id string) (*Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	device, exists := s.devices[id]
	if !exists {
		return nil, false
	}

	return &Device{
		ID:           device.ID,
		Name:         device.Name,
		Connected:    device.Connected,
		Config:       device.Config,
		SupervisorID: device.SupervisorID,
	}, true
}

func (s *OpAMPServer) GetAgent(id string) (*Agent, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	agent, exists := s.agents[id]
	if !exists {
		return nil, false
	}

	agent.mu.RLock()
	defer agent.mu.RUnlock()

	return &Agent{
		ID:        agent.ID,
		Name:      agent.Name,
		Connected: agent.Connected,
		Config:    agent.Config,
	}, true
}

func (s *OpAMPServer) PushConfig(deviceID, config string) error {
	s.mu.RLock()
	device, exists := s.devices[deviceID]
	if !exists {
		s.mu.RUnlock()
		return fmt.Errorf("device %s not found", deviceID)
	}

	if !device.Connected {
		s.mu.RUnlock()
		return fmt.Errorf("device %s is not connected", deviceID)
	}

	supervisorID := device.SupervisorID
	agent, agentExists := s.agents[supervisorID]
	s.mu.RUnlock()

	if !agentExists {
		return fmt.Errorf("supervisor %s not found for device %s", supervisorID, deviceID)
	}

	if !agent.Connected {
		return fmt.Errorf("supervisor %s is not connected", supervisorID)
	}

	// Store the config
	device.Config = config

	// Create RemoteConfig message with device ID as key
	remoteConfig := &protobufs.AgentRemoteConfig{
		Config: &protobufs.AgentConfigMap{
			ConfigMap: map[string]*protobufs.AgentConfigFile{
				deviceID: {
					Body:        []byte(config),
					ContentType: "text/yaml",
				},
			},
		},
	}

	// Convert supervisor UUID string back to bytes
	supervisorUUID, err := uuid.Parse(supervisorID)
	if err != nil {
		return fmt.Errorf("invalid supervisor UUID: %w", err)
	}

	// Send configuration to supervisor (which will forward to device)
	err = agent.conn.Send(context.Background(), &protobufs.ServerToAgent{
		InstanceUid:  supervisorUUID[:],
		RemoteConfig: remoteConfig,
	})

	if err != nil {
		log.Printf("Failed to send config to device %s via supervisor %s: %v", deviceID, supervisorID, err)
		return fmt.Errorf("failed to send config: %w", err)
	}

	log.Printf("Successfully pushed config to device %s via supervisor %s", deviceID, supervisorID)
	return nil
}

func getDefaultConfig(deviceID string) string {
	// Return the default configuration for each device based on its ID
	// These match the ConfigMaps deployed in Kubernetes
	configs := map[string]string{
		"device-1": `receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
  telemetry:
    logs:
      level: info`,
		"device-2": `receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
  telemetry:
    logs:
      level: info`,
		"device-3": `receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
  telemetry:
    logs:
      level: info`,
	}

	if config, exists := configs[deviceID]; exists {
		return config
	}
	return "# No default configuration available"
}

func main() {
	// Load dashboard HTML
	dashboardPath := "/internal/ui/dashboard.html"
	// Fallback to relative path for local development
	if _, err := os.Stat(dashboardPath); os.IsNotExist(err) {
		dashboardPath = "../../internal/ui/dashboard.html"
	}

	dashboardBytes, err := os.ReadFile(dashboardPath)
	if err != nil {
		log.Fatalf("Failed to load dashboard.html: %v", err)
	}
	dashboardHTML = string(dashboardBytes)

	opampServer := NewOpAMPServer()

	// Create OpAMP server
	opampServer.server = server.New(&logger{})

	connectionCallbacks := types.ConnectionCallbacks{
		OnConnected:       opampServer.OnConnected,
		OnMessage:         opampServer.OnMessage,
		OnConnectionClose: opampServer.OnConnectionClose,
	}

	settings := server.StartSettings{
		Settings: server.Settings{
			Callbacks: types.Callbacks{
				OnConnecting: func(request *http.Request) types.ConnectionResponse {
					return types.ConnectionResponse{
						Accept:              true,
						ConnectionCallbacks: connectionCallbacks,
					}
				},
			},
		},
		ListenEndpoint: "0.0.0.0:4320",
	}

	err = opampServer.server.Start(settings)
	if err != nil {
		log.Fatalf("Failed to start OpAMP server: %v", err)
	}

	log.Println("OpAMP Server started on ws://0.0.0.0:4320")

	// HTTP Server for UI and API
	mux := http.NewServeMux()

	// Dashboard UI
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(dashboardHTML))
	})

	// API: List all agents
	mux.HandleFunc("/api/agents", func(w http.ResponseWriter, r *http.Request) {
		agents := opampServer.GetAgents()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"agents": agents,
		})
	})

	// API: List all devices (OTel agents)
	mux.HandleFunc("/api/devices", func(w http.ResponseWriter, r *http.Request) {
		devices := opampServer.GetDevices()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"devices": devices,
		})
	})

	// API: Get device config
	mux.HandleFunc("/api/devices/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			// Handle POST separately
			return
		}

		// Extract device ID from path
		path := r.URL.Path
		if len(path) > len("/api/devices/") {
			deviceID := path[len("/api/devices/"):]
			// Remove "/config" suffix if present
			if len(deviceID) > 7 && deviceID[len(deviceID)-7:] == "/config" {
				deviceID = deviceID[:len(deviceID)-7]
			}

			device, exists := opampServer.GetDevice(deviceID)
			if !exists {
				http.Error(w, "Device not found", http.StatusNotFound)
				return
			}

			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"id":     device.ID,
				"name":   device.Name,
				"config": device.Config,
			})
			return
		}
		http.Error(w, "Invalid request", http.StatusBadRequest)
	})

	// API: Get agent config
	mux.HandleFunc("/api/agents/", func(w http.ResponseWriter, r *http.Request) {
		// Extract agent ID from path
		path := r.URL.Path
		if len(path) > len("/api/agents/") {
			agentID := path[len("/api/agents/"):]
			// Remove "/config" suffix if present
			if len(agentID) > 7 && agentID[len(agentID)-7:] == "/config" {
				agentID = agentID[:len(agentID)-7]
			}

			agent, exists := opampServer.GetAgent(agentID)
			if !exists {
				http.Error(w, "Agent not found", http.StatusNotFound)
				return
			}

			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"id":     agent.ID,
				"name":   agent.Name,
				"config": agent.Config,
			})
			return
		}
		http.Error(w, "Invalid request", http.StatusBadRequest)
	})

	// API: Push config to agent
	mux.HandleFunc("/api/devices/config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req struct {
			DeviceID string `json:"deviceId"`
			AgentID  string `json:"agentId"` // Support both field names
			Config   string `json:"config"`
		}

		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}

		// Use DeviceID if set, otherwise use AgentID for backward compatibility
		deviceID := req.DeviceID
		if deviceID == "" {
			deviceID = req.AgentID
		}

		if err := opampServer.PushConfig(deviceID, req.Config); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]interface{}{
				"error": err.Error(),
			})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": true,
			"message": "Configuration pushed successfully to device",
		})
	})

	log.Println("HTTP Server (UI + API) starting on http://0.0.0.0:4321")
	if err := http.ListenAndServe(":4321", mux); err != nil {
		log.Fatalf("Failed to start HTTP server: %v", err)
	}
}

// Simple logger implementation
type logger struct{}

func (l *logger) Debugf(ctx context.Context, format string, v ...interface{}) {
	log.Printf("[DEBUG] "+format, v...)
}

func (l *logger) Errorf(ctx context.Context, format string, v ...interface{}) {
	log.Printf("[ERROR] "+format, v...)
}
