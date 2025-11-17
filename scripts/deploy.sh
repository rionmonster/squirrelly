#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root directory (parent of scripts/)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Change to project root so all paths work correctly
cd "${PROJECT_ROOT}"

NAMESPACE="squirrly"
IMAGE_NAME="squirrly-flink-job"
IMAGE_TAG="latest"
FLINK_UI_PORT=8081
FLINK_DEPLOYMENT_NAME="sample-job"

echo "🚀 Deploying Squirrly Flink Job to Kubernetes using Flink Kubernetes Operator..."

# Check if minikube is running, start it if not
if ! minikube status > /dev/null 2>&1; then
    echo "⚠️ Minikube is not running. Starting minikube..."
    minikube start
    if [ $? -ne 0 ]; then
        echo "❌ Failed to start minikube. Please check your minikube installation."
        exit 1
    fi
    echo "✅ Minikube started successfully"
else
    echo "✅ Minikube is already running"
fi

# Check if Flink Kubernetes Operator is installed
echo "🔍 Checking for Flink Kubernetes Operator..."
OPERATOR_INSTALLED=false

# Check if CRD exists (CRDs are cluster-scoped, no namespace needed)
if kubectl get crd flinkdeployments.flink.apache.org > /dev/null 2>&1; then
    # Check if operator deployment actually exists and is running
    if kubectl get deployment flink-kubernetes-operator -n flink-operator > /dev/null 2>&1; then
        # Check if deployment is ready
        if kubectl get deployment flink-kubernetes-operator -n flink-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
            OPERATOR_INSTALLED=true
        fi
    fi
fi

if [ "$OPERATOR_INSTALLED" = false ]; then
    echo "⚠️ Flink Kubernetes Operator not found or not running. Installing..."
    echo "📦 Installing Flink Kubernetes Operator via Helm..."
    
    # Add Flink Operator Helm repo (using latest stable version 1.13.0)
    helm repo add flink-kubernetes-operator https://archive.apache.org/dist/flink/flink-kubernetes-operator-1.13.0/ || {
        echo "⚠️ Failed to add Helm repo, trying to update existing one..."
        helm repo update flink-kubernetes-operator || true
    }
    helm repo update
    
    # Install the operator
    helm install flink-kubernetes-operator flink-kubernetes-operator/flink-kubernetes-operator \
        --namespace flink-operator \
        --create-namespace \
        --set webhook.create=false || {
        echo "❌ Failed to install Flink Kubernetes Operator. Please install it manually."
        echo "   See: https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/docs/try-flink-kubernetes-operator/quick-start/"
        exit 1
    }
    
    echo "⏳ Waiting for operator to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/flink-kubernetes-operator -n flink-operator || {
        echo "⚠️ Operator may still be starting. Continuing..."
    }
else
    echo "✅ Flink Kubernetes Operator is installed and running"
fi

# Build the project
echo "📦 Building the Flink job..."
# Ensure we're using Java 21
if [ -z "$JAVA_HOME" ] || ! java -version 2>&1 | grep -q "version \"21"; then
    echo "⚠️ Setting JAVA_HOME to Java 21..."
    export JAVA_HOME=$(/usr/libexec/java_home -v 21 2>/dev/null || echo "")
    if [ -z "$JAVA_HOME" ]; then
        echo "❌ Java 21 not found. Please install Java 21 or set JAVA_HOME manually."
        exit 1
    fi
fi
mvn clean package

# Build Docker image
echo "🐳 Building Docker image..."
eval $(minikube docker-env)
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .

# Create namespace
echo "📝 Creating namespace..."
kubectl apply -f k8s/namespace.yaml

# Wait for namespace to be ready
kubectl wait --for=condition=Active namespace/${NAMESPACE} --timeout=30s || true

# Delete existing FlinkDeployment if it exists (for clean redeployment)
echo "🧹 Cleaning up any existing FlinkDeployment..."
kubectl delete flinkdeployment ${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE} 2>/dev/null || true
kubectl wait --for=delete flinkdeployment/${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE} --timeout=60s 2>/dev/null || true

# Deploy ServiceAccount and RBAC first
echo "👤 Creating ServiceAccount and RBAC..."
kubectl apply -f k8s/sample-job/serviceaccount.yaml
kubectl apply -f k8s/sample-job/role.yaml
kubectl apply -f k8s/sample-job/rolebinding.yaml

# Deploy Flink application using FlinkDeployment
echo "🚀 Deploying Flink application via FlinkDeployment..."
kubectl apply -f k8s/sample-job/flink-deployment.yaml

# Wait for FlinkDeployment to be ready
echo "⏳ Waiting for FlinkDeployment to be ready..."
kubectl wait --for=condition=ready --timeout=300s flinkdeployment/${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE} || {
    echo "⚠️ FlinkDeployment may still be starting. Checking status..."
    kubectl get flinkdeployment ${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE}
    kubectl describe flinkdeployment ${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE} | tail -20
}

# Get the JobManager service name (operator creates service with deployment name)
JOBMANAGER_SERVICE="${FLINK_DEPLOYMENT_NAME}-rest"

# Wait for JobManager service to be available
echo "⏳ Waiting for JobManager service..."
for i in {1..30}; do
    if kubectl get service ${JOBMANAGER_SERVICE} -n ${NAMESPACE} > /dev/null 2>&1; then
        echo "✅ JobManager service is available"
        break
    fi
    sleep 2
done

# Set up port forwarding in background
echo "🔌 Setting up port forwarding for Flink UI..."
# Kill any existing port-forward on this port
lsof -ti:${FLINK_UI_PORT} | xargs kill -9 2>/dev/null || true
sleep 1

kubectl port-forward -n ${NAMESPACE} service/${JOBMANAGER_SERVICE} ${FLINK_UI_PORT}:8081 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait a moment for port forwarding to establish
sleep 3

# Verify port forwarding is working
if ! lsof -ti:${FLINK_UI_PORT} > /dev/null 2>&1; then
    echo "⚠️ Warning: Port forwarding may not have started correctly"
else
    echo ""
    echo "✅ Deployment complete!"
    echo ""
    echo "📊 Flink UI is available at: http://localhost:${FLINK_UI_PORT}"
    echo "🛑 To stop port forwarding, run: kill ${PORT_FORWARD_PID}"
    echo "🗑️ To clean up, run: kubectl delete flinkdeployment ${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE}"
    echo "   Or delete namespace: kubectl delete namespace ${NAMESPACE}"
    echo ""
    echo "📋 Check FlinkDeployment status:"
    echo "   kubectl get flinkdeployment ${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE}"
    echo ""
fi

