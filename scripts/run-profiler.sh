#!/bin/bash

set -e

NAMESPACE="${NAMESPACE:-squirrly}"
JOB_NAME="squirrly-profiler"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Output mode: "inline" (default) or "file"
OUTPUT_MODE="inline"
OUTPUT_FILE=""

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output)
                OUTPUT_FILE="$2"
                OUTPUT_MODE="file"
                shift 2
                ;;
            --inline)
                OUTPUT_MODE="inline"
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  -o, --output FILE    Save profiler output to FILE"
                echo "  --inline             Display output inline to terminal (default)"
                echo "  -h, --help           Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                  # Display output inline"
                echo "  $0 --inline         # Display output inline (explicit)"
                echo "  $0 -o profiler.log  # Save output to profiler.log"
                echo "  $0 --output ./logs/profiler-$(date +%Y%m%d).log  # Save to specific file"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Create/update ConfigMap (for profiler.sh script and prompt.md)
create_profiler_configmap() {
    echo "📝 Creating/updating ConfigMap from profiler.sh and prompt.md..."
    kubectl create configmap squirrly-profiler-script \
        --from-file=profiler.sh=${PROJECT_ROOT}/k8s/squirrly-profiler/profiler.sh \
        --from-file=prompt.md=${PROJECT_ROOT}/k8s/squirrly-profiler/prompt.md \
        --namespace=${NAMESPACE} \
        --dry-run=client -o yaml | kubectl apply -f -
}

# Delete existing job (if it exists)
cleanup_existing_job() {
    if kubectl get job ${JOB_NAME} --namespace ${NAMESPACE} > /dev/null 2>&1; then
        echo "🧹 Deleting existing profiler job..."
        kubectl delete job ${JOB_NAME} --namespace ${NAMESPACE} > /dev/null 2>&1
        sleep 2
    fi
}

# Apply the job with API key injection if provided
apply_profiler_job() {
    echo "🚀 Creating new profiler job..."
    if [ -n "$OPENAI_API_KEY" ]; then
        echo "🔑 OPENAI_API_KEY found in environment, injecting into job..."
        # Create temporary job file with API key substituted
        local temp_job=$(mktemp)
        
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
        ' ${PROJECT_ROOT}/k8s/squirrly-profiler/job.yaml > ${temp_job}
        
        kubectl apply -f ${temp_job}
        rm -f ${temp_job}
    else
        echo "ℹ️ OPENAI_API_KEY not set in environment (analysis will be skipped unless API key is configured)"
        kubectl apply -f ${PROJECT_ROOT}/k8s/squirrly-profiler/job.yaml
    fi
}

# Wait for job to start and verify it was created successfully
verify_job_created() {
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
}

# Wait for job pod to be ready
wait_for_job_pod() {
    echo "⏳ Waiting for profiler pod to be ready..."
    local max_wait=120  # 2 minutes
    local elapsed=0
    local interval=2
    
    while [ $elapsed -lt $max_wait ]; do
        local pod_name=$(kubectl get pods --namespace "${NAMESPACE}" \
            -l job-name="${JOB_NAME}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$pod_name" ]; then
            local pod_status=$(kubectl get pod "${pod_name}" --namespace "${NAMESPACE}" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [ "$pod_status" = "Running" ] || [ "$pod_status" = "Succeeded" ] || [ "$pod_status" = "Failed" ]; then
                echo "✅ Pod ${pod_name} is ${pod_status}"
                echo "${pod_name}"
                return 0
            fi
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo "⚠️ Timeout waiting for pod to be ready"
    return 1
}

# Get job pod name
get_job_pod_name() {
    kubectl get pods --namespace "${NAMESPACE}" \
        -l job-name="${JOB_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Wait for job to complete
wait_for_job_completion() {
    local pod_name=$1
    echo "⏳ Waiting for profiler job to complete..."
    
    if [ -z "$pod_name" ]; then
        echo "⚠️ No pod name provided, skipping wait"
        return 1
    fi
    
    # Wait for the pod to reach a terminal state
    kubectl wait --for=condition=Ready=False --timeout=600s "pod/${pod_name}" --namespace "${NAMESPACE}" 2>/dev/null || \
    kubectl wait --for=condition=Ready=True --timeout=600s "pod/${pod_name}" --namespace "${NAMESPACE}" 2>/dev/null || true
    
    # Check final status
    local pod_status=$(kubectl get pod "${pod_name}" --namespace "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    echo "📊 Job completed with status: ${pod_status}"
    return 0
}

# Display or save job logs
handle_job_output() {
    local pod_name=$1
    
    if [ -z "$pod_name" ]; then
        echo "⚠️ No pod found for job ${JOB_NAME}"
        return 1
    fi
    
    # Verify pod exists before trying to get logs
    if ! kubectl get pod "${pod_name}" --namespace "${NAMESPACE}" > /dev/null 2>&1; then
        echo "⚠️ Pod ${pod_name} not found in namespace ${NAMESPACE}"
        echo "   Attempting to find pod for job ${JOB_NAME}..."
        local found_pod=$(get_job_pod_name)
        if [ -n "$found_pod" ]; then
            echo "   Found pod: ${found_pod}"
            pod_name="${found_pod}"
        else
            echo "❌ No pod found for job ${JOB_NAME}"
            return 1
        fi
    fi
    
    if [ "$OUTPUT_MODE" = "file" ]; then
        # For file mode, wait for completion then save all logs
        echo "⏳ Waiting for job to complete before saving logs..."
        wait_for_job_completion "${pod_name}"
        
        # Ensure output directory exists
        local output_dir=$(dirname "${OUTPUT_FILE}")
        if [ -n "$output_dir" ] && [ "$output_dir" != "." ]; then
            mkdir -p "${output_dir}" || {
                echo "❌ Failed to create output directory: ${output_dir}"
                return 1
            }
        fi
        
        echo "💾 Saving profiler output to: ${OUTPUT_FILE}"
        kubectl logs "${pod_name}" --namespace "${NAMESPACE}" > "${OUTPUT_FILE}" 2>&1
        
        if [ $? -eq 0 ]; then
            local file_size=$(wc -c < "${OUTPUT_FILE}" 2>/dev/null || echo "0")
            echo "✅ Output saved successfully (${file_size} bytes)"
            echo "📄 File: ${OUTPUT_FILE}"
        else
            echo "❌ Failed to save output to file"
            return 1
        fi
    else
        # Inline output: follow logs in real-time
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📋 Profiler Output (following logs in real-time):"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Follow logs in real-time - this will block until the pod terminates
        kubectl logs -f "${pod_name}" --namespace "${NAMESPACE}" 2>&1
        
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Check final status after logs complete
        local pod_status=$(kubectl get pod "${pod_name}" --namespace "${NAMESPACE}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo "📊 Job completed with status: ${pod_status}"
    fi
}

# Main execution
parse_arguments "$@"

echo "🐿️ Running Squirrly Profiler..."
if [ "$OUTPUT_MODE" = "file" ]; then
    echo "📁 Output will be saved to: ${OUTPUT_FILE}"
else
    echo "📺 Output will be displayed inline"
fi
echo ""

create_profiler_configmap
cleanup_existing_job
apply_profiler_job
verify_job_created

# Wait for pod and get logs
POD_NAME=$(wait_for_job_pod)
if [ -z "$POD_NAME" ]; then
    echo "❌ Failed to get pod name"
    exit 1
fi

# For inline mode, handle_job_output will follow logs in real-time
# For file mode, handle_job_output will wait for completion then save
handle_job_output "${POD_NAME}"


