#!/bin/bash

set -e

NAMESPACE="${NAMESPACE:-squirrly}"
JOB_NAME="squirrly-profiler"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "🐿️ Running Squirrly Profiler..."
echo ""

# Create/update ConfigMap from profiler.sh script and prompt.md
echo "📝 Creating/updating ConfigMap from profiler.sh and prompt.md..."
kubectl create configmap squirrly-profiler-script \
    --from-file=profiler.sh=${PROJECT_ROOT}/k8s/squirrly-profiler/profiler.sh \
    --from-file=prompt.md=${PROJECT_ROOT}/k8s/squirrly-profiler/prompt.md \
    --namespace=${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -

# Delete existing job if it exists
if kubectl get job ${JOB_NAME} --namespace ${NAMESPACE} > /dev/null 2>&1; then
    echo "🧹 Deleting existing profiler job..."
    kubectl delete job ${JOB_NAME} --namespace ${NAMESPACE} > /dev/null 2>&1
    sleep 2
fi

# Apply the job (with API key if provided)
echo "🚀 Creating new profiler job..."
if [ -n "$OPENAI_API_KEY" ]; then
    echo "🔑 OPENAI_API_KEY found in environment, injecting into job..."
    # Create temporary job file with API key substituted
    TEMP_JOB=$(mktemp)
    
    # Use awk to replace the API key value, handling special characters properly
    # This reads the YAML line by line and replaces the empty value with the actual key
    awk -v api_key="${OPENAI_API_KEY}" '
    /value: ""  # OpenAI API key/ {
        # Escape any double quotes and backslashes in the API key for YAML
        gsub(/\\/, "\\\\", api_key)
        gsub(/"/, "\\\"", api_key)
        # Match the indentation and preserve the full comment
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        # Extract the comment part (everything after the value)
        if (match($0, /[[:space:]]+#.*$/)) {
            comment = substr($0, RSTART)
        } else {
            comment = "  # OpenAI API key"
        }
        print indent "value: \"" api_key "\"" comment
        next
    }
    { print }
    ' ${PROJECT_ROOT}/k8s/squirrly-profiler/job.yaml > ${TEMP_JOB}
    
    kubectl apply -f ${TEMP_JOB}
    rm -f ${TEMP_JOB}
else
    echo "ℹ️ OPENAI_API_KEY not set in environment (analysis will be skipped unless API key is configured)"
    kubectl apply -f ${PROJECT_ROOT}/k8s/squirrly-profiler/job.yaml
fi

# Wait a moment for the pod to start
sleep 5

# Check if job was created successfully
if kubectl get job ${JOB_NAME} --namespace ${NAMESPACE} > /dev/null 2>&1; then
    echo "✅ Profiler job created successfully"
    echo ""
    echo "📊 Job status:"
    kubectl get job ${JOB_NAME} --namespace ${NAMESPACE}
    echo ""
else
    echo "❌ Failed to create profiler job"
    exit 1
fi


