#!/bin/bash

set -e

NAMESPACE="${NAMESPACE:-squirrly}"
JOB_NAME="squirrly-profiler"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "🔬 Running Squirrly Profiler..."
echo ""

# Create/update ConfigMap from profiler.sh script
echo "📝 Creating/updating ConfigMap from profiler.sh..."
kubectl create configmap squirrly-profiler-script \
    --from-file=profiler.sh=${PROJECT_ROOT}/k8s/squirrly-profiler/profiler.sh \
    --namespace=${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -

# Delete existing job if it exists
if kubectl get job ${JOB_NAME} -n ${NAMESPACE} > /dev/null 2>&1; then
    echo "🧹 Deleting existing profiler job..."
    kubectl delete job ${JOB_NAME} -n ${NAMESPACE} > /dev/null 2>&1
    sleep 2
fi

# Apply the job
echo "🚀 Creating new profiler job..."
kubectl apply -f ${PROJECT_ROOT}/k8s/squirrly-profiler/job.yaml

# Wait a moment for the pod to start
sleep 5

# Check if job was created successfully
if kubectl get job ${JOB_NAME} -n ${NAMESPACE} > /dev/null 2>&1; then
    echo "✅ Profiler job created successfully"
    echo ""
    echo "📊 Job status:"
    kubectl get job ${JOB_NAME} -n ${NAMESPACE}
    echo ""
else
    echo "❌ Failed to create profiler job"
    exit 1
fi


