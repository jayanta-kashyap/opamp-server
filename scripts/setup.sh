#!/bin/bash

# OpAMP POC - Complete Setup Script
# Usage: ./scripts/setup.sh [number-of-devices]
# Example: ./scripts/setup.sh 20
# 
# This script sets up the entire OpAMP POC from scratch:
# 1. Starts minikube (if not running)
# 2. Creates namespaces
# 3. Builds all Docker images
# 4. Deploys cloud components (server + supervisor)
# 5. Deploys N edge devices (default: 5)
# 6. Starts port-forward for UI access

set -e

# Number of devices to deploy (default: 1)
DEVICE_COUNT=${1:-1}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE_DIR="$(dirname "$SERVER_DIR")"
SUPERVISOR_DIR="$WORKSPACE_DIR/opamp-supervisor"
DEVICE_AGENT_DIR="$WORKSPACE_DIR/opamp-device-agent"

CONTEXT="control-plane"
CONTROL_NS="opamp-control"
EDGE_NS="opamp-edge"

echo "=============================================="
echo "  OpAMP POC - Complete Setup"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Devices to deploy: $DEVICE_COUNT"
echo ""
echo "Directories:"
echo "  Server:       $SERVER_DIR"
echo "  Supervisor:   $SUPERVISOR_DIR"
echo "  Device-Agent: $DEVICE_AGENT_DIR"
echo ""

# Check prerequisites
check_prerequisites() {
    echo "📋 Checking prerequisites..."
    
    for cmd in minikube kubectl docker; do
        if ! command -v $cmd &> /dev/null; then
            echo "❌ $cmd is not installed"
            exit 1
        fi
    done
    echo "✅ All prerequisites installed"
}

# Start minikube if not running
start_minikube() {
    echo ""
    echo "🚀 Starting Minikube..."
    
    if minikube status -p $CONTEXT 2>/dev/null | grep -q "Running"; then
        echo "✅ Minikube already running"
    else
        echo "Starting minikube cluster..."
        minikube start -p $CONTEXT --cpus=4 --memory=6144 --disk-size=20g
        echo "✅ Minikube started"
    fi
}

# Create namespaces
create_namespaces() {
    echo ""
    echo "📁 Creating namespaces..."
    
    kubectl --context $CONTEXT create namespace $CONTROL_NS 2>/dev/null || echo "   $CONTROL_NS already exists"
    kubectl --context $CONTEXT create namespace $EDGE_NS 2>/dev/null || echo "   $EDGE_NS already exists"
    
    echo "✅ Namespaces ready"
}

# Build Docker images
build_images() {
    echo ""
    echo "🔨 Building Docker images..."
    
    # Set Docker to use Minikube's daemon
    eval $(minikube -p $CONTEXT docker-env)
    
    echo "Building opamp-server..."
    docker build -f "$SERVER_DIR/DockerFile" -t opamp-server:v1 "$SERVER_DIR" -q
    
    echo "Building opamp-supervisor..."
    docker build -t opamp-supervisor:v10 "$SUPERVISOR_DIR" -q
    
    echo "Building opamp-device-agent..."
    docker build -t opamp-device-agent:v1 "$DEVICE_AGENT_DIR" -q
    
    echo "Building poc-provisioner..."
    docker build -t poc-provisioner:v1 "$DEVICE_AGENT_DIR/poc-provisioner" -q
    
    echo "✅ All images built"
}

# Deploy cloud components
deploy_cloud() {
    echo ""
    echo "☁️  Deploying cloud components..."
    
    echo "Deploying OpAMP Server..."
    kubectl --context $CONTEXT apply -f "$SERVER_DIR/opamp-server.yaml"
    
    echo "Deploying OpAMP Supervisor..."
    kubectl --context $CONTEXT apply -f "$SUPERVISOR_DIR/k8s/supervisor.yaml"
    
    echo "Deploying POC Provisioner..."
    kubectl --context $CONTEXT apply -f "$DEVICE_AGENT_DIR/poc-provisioner/k8s/poc-provisioner.yaml"
    
    echo "Waiting for cloud components to be ready..."
    kubectl --context $CONTEXT wait --for=condition=available --timeout=120s \
        deployment/opamp-server deployment/opamp-supervisor deployment/poc-provisioner -n $CONTROL_NS
    
    echo "✅ Cloud components deployed"
}

# Deploy edge devices using batch script
deploy_devices() {
    echo ""
    echo "📱 Deploying $DEVICE_COUNT edge devices..."
    
    cd "$DEVICE_AGENT_DIR"
    
    # Make sure batch script is executable
    chmod +x ./scripts/add-devices-batch.sh
    
    # Deploy N devices in one batch (device-1 through device-N)
    ./scripts/add-devices-batch.sh 1 $DEVICE_COUNT
    
    cd "$SERVER_DIR"
    
    echo "✅ All $DEVICE_COUNT edge devices deployed"
}

# Start port-forward
start_port_forward() {
    echo ""
    echo "🌐 Starting port-forward..."
    
    "$SCRIPT_DIR/start-port-forward.sh"
}

# Show status
show_status() {
    echo ""
    echo "=============================================="
    echo "  Setup Complete!"
    echo "=============================================="
    echo ""
    echo "📊 Pod Status:"
    echo ""
    echo "Cloud (opamp-control):"
    kubectl --context $CONTEXT get pods -n $CONTROL_NS
    echo ""
    echo "Edge (opamp-edge):"
    kubectl --context $CONTEXT get pods -n $EDGE_NS
    echo ""
    echo "=============================================="
    echo "  Access"
    echo "=============================================="
    echo ""
    echo "🌐 Web UI: http://localhost:4321"
    echo ""
    echo "📝 Useful commands:"
    echo "   View logs:     kubectl --context $CONTEXT logs -n opamp-control -l app=opamp-server -f"
    echo "   Add device:    cd $DEVICE_AGENT_DIR && ./scripts/add-device.sh <number>"
    echo "   Remove device: cd $DEVICE_AGENT_DIR && ./scripts/remove-device.sh <number>"
    echo "   Stop port-forward: $SCRIPT_DIR/stop-port-forward.sh"
    echo ""
    echo "ℹ️  Port-forward auto-restarts if connection drops"
    echo ""
}

# Main
check_prerequisites
start_minikube
create_namespaces
build_images
deploy_cloud
deploy_devices
start_port_forward
show_status
