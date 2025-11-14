#!/bin/bash

set -e

NAMESPACE="squirrly"
IMAGE_NAME="squirrly-flink-job"
IMAGE_TAG="latest"
FLINK_UI_PORT=8081

echo "🚀 Deploying Squirrly Flink Job to Kubernetes..."

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

# Clean up any existing deployments to ensure fresh start
echo "🧹 Cleaning up any existing deployments..."
kubectl delete deployment flink-jobmanager flink-taskmanager -n ${NAMESPACE} 2>/dev/null || true
kubectl wait --for=delete deployment/flink-jobmanager -n ${NAMESPACE} --timeout=60s 2>/dev/null || true
kubectl wait --for=delete deployment/flink-taskmanager -n ${NAMESPACE} --timeout=60s 2>/dev/null || true

# Deploy Flink JobManager
echo "👔 Deploying Flink JobManager..."
kubectl apply -f k8s/jobmanager-deployment.yaml
kubectl apply -f k8s/jobmanager-service.yaml

# Wait for JobManager to be ready
echo "⏳ Waiting for JobManager to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/flink-jobmanager -n ${NAMESPACE}

# Copy JAR to JobManager pod
echo "📤 Copying JAR to JobManager..."
JOBMANAGER_POD=$(kubectl get pods -n ${NAMESPACE} -l component=jobmanager -o jsonpath='{.items[0].metadata.name}')
kubectl cp target/squirrly-1.0.0.jar ${NAMESPACE}/${JOBMANAGER_POD}:/opt/flink/lib/squirrly-1.0.0.jar

# Deploy Flink TaskManager
echo "⚙️  Deploying Flink TaskManager..."
kubectl apply -f k8s/taskmanager-deployment.yaml

# Wait for TaskManager to be ready
echo "⏳ Waiting for TaskManager to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/flink-taskmanager -n ${NAMESPACE}

# Copy JAR to TaskManager pod
echo "📤 Copying JAR to TaskManager..."
TASKMANAGER_POD=$(kubectl get pods -n ${NAMESPACE} -l component=taskmanager -o jsonpath='{.items[0].metadata.name}')
kubectl cp target/squirrly-1.0.0.jar ${NAMESPACE}/${TASKMANAGER_POD}:/opt/flink/lib/squirrly-1.0.0.jar

# Submit the Flink job
echo "🎯 Submitting Flink job..."
JOBMANAGER_POD=$(kubectl get pods -n ${NAMESPACE} -l component=jobmanager -o jsonpath='{.items[0].metadata.name}')

# Check if a job is already running and cancel it if needed
echo "🔍 Checking for existing jobs..."
# Get list of running jobs and extract job IDs
JOB_LIST=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- /opt/flink/bin/flink list 2>/dev/null || echo "")

if [ -n "$JOB_LIST" ]; then
    # Try to find job ID - Flink list output format varies, try multiple patterns
    # Pattern 1: "Job ID: <id>" or similar
    EXISTING_JOB_ID=$(echo "$JOB_LIST" | grep -i "job id" | sed -E 's/.*[Jj]ob [Ii][Dd]:[[:space:]]*([a-f0-9]+).*/\1/' | head -1 | tr -d '[:space:]' || echo "")
    
    # If that didn't work, try to extract any hex ID from the output
    if [ -z "$EXISTING_JOB_ID" ]; then
        EXISTING_JOB_ID=$(echo "$JOB_LIST" | grep -oE '[a-f0-9]{32,}' | head -1 || echo "")
    fi
    
    if [ -n "$EXISTING_JOB_ID" ] && [ ${#EXISTING_JOB_ID} -ge 32 ]; then
        echo "⚠️  Found existing job with ID: $EXISTING_JOB_ID"
        echo "🛑 Canceling existing job..."
        kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- /opt/flink/bin/flink cancel $EXISTING_JOB_ID 2>/dev/null || true
        # Wait a moment for cancellation to complete
        sleep 3
        echo "✅ Existing job canceled"
    else
        echo "ℹ️  No existing jobs found"
    fi
else
    echo "ℹ️  Could not check for existing jobs (JobManager may still be starting)"
fi

# Submit the new job
echo "📤 Submitting new Flink job..."
kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- /opt/flink/bin/flink run \
    --class dev.squirrly.SimpleFlinkJob \
    /opt/flink/lib/squirrly-1.0.0.jar

# Set up port forwarding in background
echo "🔌 Setting up port forwarding for Flink UI..."
# Kill any existing port-forward on this port
lsof -ti:${FLINK_UI_PORT} | xargs kill -9 2>/dev/null || true
sleep 1

kubectl port-forward -n ${NAMESPACE} service/flink-jobmanager ${FLINK_UI_PORT}:8081 > /dev/null 2>&1 &
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
    echo "🗑️ To clean up, run: kubectl delete namespace ${NAMESPACE}"
    echo ""
fi

