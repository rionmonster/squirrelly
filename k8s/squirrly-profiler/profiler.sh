#!/bin/bash

set -e

NAMESPACE="${NAMESPACE:-squirrly}"
FLINK_DEPLOYMENT_NAME="${FLINK_DEPLOYMENT_NAME:-sample-job}"  # Name of the FlinkDeployment to profile
PROFILER_TYPE="${PROFILER_TYPE:-ITIMER}"      # CPU, ITIMER, or ALLOC
PROFILER_DURATION="${PROFILER_DURATION:-60}"  # Duration in seconds
PROFILER_OUTPUT_DIR="${PROFILER_OUTPUT_DIR:-/tmp /opt/flink/log /opt/flink}"  # Directories to search for profiler artifacts (space-separated)
API_PROVIDER="${API_PROVIDER:-openai}"  # API provider: openai (others can be added later)
OPENAI_API_KEY="${OPENAI_API_KEY:-}"  # OpenAI API key for analysis
ANALYSIS_PROMPT_FILE="${ANALYSIS_PROMPT_FILE:-/scripts/prompt.md}"  # Path to prompt file

# Output options:
#  --inline (default)        Print analysis to stdout
#  --output-file <path>      Write analysis output to given file path
#  --output-dir <dir>        Write analysis output to given directory with generated filename
OUTPUT_FILE=""
OUTPUT_DIR=""

# Parse CLI arguments
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --output-file)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --inline)
                # explicit inline, do nothing (default)
                shift
                ;;
            *)
                # unknown arg - skip
                shift
                ;;
        esac
    done
}

# Verify FlinkDeployment exists
verify_flink_deployment() {
    if ! kubectl get flinkdeployment "${FLINK_DEPLOYMENT_NAME}" --namespace "${NAMESPACE}" > /dev/null 2>&1; then
        echo "❌ FlinkDeployment '${FLINK_DEPLOYMENT_NAME}' not found in namespace ${NAMESPACE}"
        exit 1
    fi
}

# Get JobManager pod
get_jobmanager_pod() {
    local deployment_name=$1
    local pod_name=$(kubectl get pods --namespace "${NAMESPACE}" \
        -l app="${deployment_name}",component=jobmanager \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$pod_name" ]; then
        echo "❌ JobManager pod not found for ${deployment_name}"
        exit 1
    fi
    
    echo "${pod_name}"
}

# Verify REST service exists
verify_rest_service() {
    local rest_service=$1
    if ! kubectl get service "${rest_service}" --namespace "${NAMESPACE}" > /dev/null 2>&1; then
        echo "❌ REST service ${rest_service} not found"
        exit 1
    fi
}

# Get running job ID from Flink REST API
get_job_id() {
    local jobmanager_pod=$1
    local rest_url=$2
    
    echo "🔍 Fetching job information..."
    local job_list=$(kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        curl -s "${rest_url}/jobs" 2>/dev/null || echo "")
    
    if [ -z "$job_list" ]; then
        echo "❌ Could not retrieve job list from REST API"
        exit 1
    fi
    
    # Extract job ID from job list (get the first running job)
    local job_id=$(echo "$job_list" | grep -oE '"id":"[a-f0-9]+"' | head -1 | cut -d'"' -f4 || echo "")
    
    if [ -z "$job_id" ]; then
        echo "❌ No running job found for ${FLINK_DEPLOYMENT_NAME}"
        echo "   Job list response: $job_list"
        exit 1
    fi
    
    echo "${job_id}"
}

# Get vertex ID from job details
get_vertex_id() {
    local jobmanager_pod=$1
    local rest_url=$2
    local job_id=$3
    
    echo "🔍 Fetching job details to find vertices..."
    local job_details=$(kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        curl -s "${rest_url}/jobs/${job_id}" 2>/dev/null || echo "")
    
    if [ -z "$job_details" ]; then
        echo "❌ Could not retrieve job details"
        exit 1
    fi
    
    # Extract vertex ID from job details (get the first vertex/operator)
    local vertex_id=$(echo "$job_details" | grep -oE '"id":"[a-f0-9-]+"' | head -1 | cut -d'"' -f4 || echo "")
    
    if [ -z "$vertex_id" ]; then
        echo "❌ Could not extract vertex ID from job details"
        echo "   Attempting to find vertices in response..."
        echo "$job_details" | grep -i "vertex\|operator" | head -5
        exit 1
    fi
    
    echo "${vertex_id}"
}

# Get TaskManager ID (use the first available TaskManager)
get_taskmanager_id() {
    local jobmanager_pod=$1
    local rest_url=$2
    
    local taskmanager_id=$(kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        curl -s "${rest_url}/taskmanagers" 2>/dev/null | \
        grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4 || echo "")
    
    if [ -z "$taskmanager_id" ]; then
        echo "   ❌ Could not find TaskManager ID"
        exit 1
    fi
    
    echo "${taskmanager_id}"
}

# Trigger profiler on TaskManager
trigger_profiler() {
    local jobmanager_pod=$1
    local rest_url=$2
    local taskmanager_id=$3
    
    echo ""
    echo "🐿️ Triggering Flink Profiler..."
    echo "   Type: ${PROFILER_TYPE}"
    echo "   Duration: ${PROFILER_DURATION} seconds"
    echo "   TaskManager ID: ${taskmanager_id}"
    echo "   Endpoint: ${rest_url}/taskmanagers/${taskmanager_id}/profiler"
    
    # Capture timestamp before triggering profiler to identify the artifact
    local profiler_start_time=$(date +"%Y-%m-%d_%H_%M_%S")
    echo "   Profiler run timestamp: ${profiler_start_time}"
    
    # Trigger profiler on TaskManager (endpoint expects JSON body, not query params)
    local profiler_endpoint="${rest_url}/taskmanagers/${taskmanager_id}/profiler"
    local profiler_json="{\"mode\":\"${PROFILER_TYPE}\",\"duration\":${PROFILER_DURATION}}"
    
    local profiler_response=$(kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "${profiler_json}" \
        "${profiler_endpoint}" \
        2>/dev/null || echo "")
    
    local http_code=$(echo "$profiler_response" | grep "HTTP_CODE:" | cut -d: -f2 || echo "")
    local response_body=$(echo "$profiler_response" | sed '/HTTP_CODE:/d' || echo "")
    
    # Return values via global variables (bash limitation)
    PROFILER_START_TIME="${profiler_start_time}"
    PROFILER_HTTP_CODE="${http_code}"
    PROFILER_RESPONSE_BODY="${response_body}"
}

# Search for profiler artifacts on TaskManager pods
search_for_artifacts() {
    local deployment_name=$1
    local profiler_start_time=$2
    
    echo ""
    echo "   📦 Checking for profiler artifacts on TaskManager pods..."
    
    # Get TaskManager pods
    local taskmanager_pods=$(kubectl get pods --namespace "${NAMESPACE}" \
        -l app="${deployment_name}",component=taskmanager \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$taskmanager_pods" ]; then
        echo "   ⚠️ No TaskManager pods found"
        echo "false"
        return 1
    fi
    
    local artifacts_found=false
    local max_retries=12  # Poll for up to 60 seconds (12 * 5 seconds)
    local retry_interval=5
    local timestamp_date=$(echo "${profiler_start_time}" | cut -d'_' -f1)  # YYYY-MM-DD
    local latest_artifact=""
    local artifact_pod=""
    
    for retry in $(seq 1 ${max_retries}); do
        for tm_pod in $taskmanager_pods; do
            # Search for artifacts matching our timestamp
            local search_dirs=$(echo "${PROFILER_OUTPUT_DIR}" | tr ' ' '\n' | tr '\n' ' ')
            local find_cmd="find ${search_dirs} -type f \
                \( -name '*${PROFILER_TYPE}_${timestamp_date}_*.html' -o \
                   -name '*${PROFILER_TYPE}*.html' \) \
                2>/dev/null | sort -r | head -5"
            
            local artifacts=$(kubectl exec --namespace "${NAMESPACE}" "${tm_pod}" -- \
                sh -c "${find_cmd}" 2>/dev/null || echo "")
            
            if [ -n "$artifacts" ]; then
                local artifact_list=$(echo "$artifacts" | grep -v '^$' || echo "")
                if [ -n "$artifact_list" ]; then
                    # Get the most recent artifact (first in sorted list)
                    local found_artifact=$(echo "$artifact_list" | head -1)
                    
                    if [ -n "$found_artifact" ]; then
                        if [ "$artifacts_found" = "false" ]; then
                            echo "   ✅ Found profiler artifact!"
                            artifacts_found=true
                        fi
                        
                        # Get file info for the latest artifact
                        local file_info=$(kubectl exec --namespace "${NAMESPACE}" "${tm_pod}" -- \
                            sh -c "stat -c'%s|%y' '${found_artifact}' 2>/dev/null || stat -f'%z|%Sm' '${found_artifact}' 2>/dev/null || echo 'unknown|unknown'" 2>/dev/null || echo "unknown|unknown")
                        local size=$(echo "$file_info" | cut -d'|' -f1)
                        local mtime=$(echo "$file_info" | cut -d'|' -f2)
                        
                        local match_indicator=""
                        if echo "$found_artifact" | grep -q "${timestamp_date}"; then
                            match_indicator=" ⭐ (matches this run)"
                        fi
                        
                        echo "   🎯 Artifact for this run:"
                        echo "      Path: ${found_artifact}${match_indicator}"
                        echo "      Size: ${size} bytes"
                        echo "      Modified: ${mtime}"
                        
                        latest_artifact="${found_artifact}"
                        artifact_pod="${tm_pod}"
                    fi
                fi
            fi
        done
        
        if [ "$artifacts_found" = "true" ]; then
            echo ""
            echo "   ✅ Profiler completed successfully! Artifacts generated."
            # Return values via global variables
            LATEST_ARTIFACT="${latest_artifact}"
            ARTIFACT_POD="${artifact_pod}"
            echo "true"
            return 0
        fi
        
        if [ $retry -lt ${max_retries} ]; then
            echo "   ⏳ Artifacts not ready yet, retrying in ${retry_interval} seconds... (attempt ${retry}/${max_retries})"
            sleep ${retry_interval}
        fi
    done
    
    if [ "$artifacts_found" = "false" ]; then
        echo "   ⚠️ No profiler artifacts found after ${max_retries} attempts (${max_retries} * ${retry_interval}s)"
        echo "   Note: Artifacts may be in a different location or not yet generated"
    fi
    
    echo "false"
    return 1
}

# Analyze artifact using OpenAI API
analyze_artifact_with_openai() {
    local jobmanager_pod=$1
    local artifact_pod=$2
    local artifact_path=$3
    
    echo ""
    echo "   📤 Submitting artifact for analysis..."
    
    # Read prompt from file
    if [ ! -f "${ANALYSIS_PROMPT_FILE}" ]; then
        echo "   ⚠️ Prompt file not found: ${ANALYSIS_PROMPT_FILE}"
        return 1
    fi
    
    local analysis_prompt=$(cat "${ANALYSIS_PROMPT_FILE}")
    
    # Create temporary files on JobManager pod
    local artifact_file="/tmp/profiler_artifact_$(date +%s).html"
    local prompt_file="/tmp/profiler_prompt_$(date +%s).txt"
    local json_payload_temp="/tmp/profiler_api_$(date +%s).json"
    
    # Get artifact size for verification
    local artifact_size=$(kubectl exec --namespace "${NAMESPACE}" "${artifact_pod}" -- \
        sh -c "wc -c < ${artifact_path}" 2>/dev/null || echo "0")
    
    if [ "$artifact_size" = "0" ] || [ -z "$artifact_size" ]; then
        echo "   ⚠️ Could not read artifact size from ${artifact_pod}:${artifact_path}"
        return 1
    fi
    
    echo "   📊 Artifact size: ${artifact_size} bytes"
    
    # Copy artifact from TaskManager to JobManager pod
    kubectl exec --namespace "${NAMESPACE}" "${artifact_pod}" -- \
        cat "${artifact_path}" 2>/dev/null | \
        kubectl exec -i --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "cat > ${artifact_file}" 2>/dev/null || {
        echo "   ⚠️ Failed to copy artifact content to JobManager pod"
        return 1
    }
    
    # Verify artifact was written correctly
    local verified_size=$(kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "wc -c < ${artifact_file}" 2>/dev/null || echo "0")
    
    if [ "$verified_size" != "$artifact_size" ]; then
        echo "   ⚠️ Artifact size mismatch! Expected: ${artifact_size}, Got: ${verified_size}"
        return 1
    fi
    
    echo "   ✅ Artifact copied successfully (${verified_size} bytes verified)"
    
    # Write prompt to file
    echo "$analysis_prompt" | kubectl exec -i --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "cat > ${prompt_file}" 2>/dev/null || {
        echo "   ⚠️ Failed to write prompt to JobManager pod"
        return 1
    }
    
    # Build OpenAI API JSON payload using jq
    echo "   🔨 Building JSON payload..."
    if ! kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "PROMPT=\$(cat ${prompt_file}); ARTIFACT=\$(cat ${artifact_file}); echo -e \"\${PROMPT}\n\nFlamegraph HTML content:\n\${ARTIFACT}\" | jq -Rs '{model: \"gpt-4o\", messages: [{role: \"user\", content: .}], temperature: 0.7, max_tokens: 2000}' > ${json_payload_temp}" 2>&1; then
        echo "   ⚠️ Failed to build API payload with jq"
        echo "   Debug: Checking if files exist and jq is available..."
        kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
            sh -c "ls -lh ${prompt_file} ${artifact_file} 2>&1; command -v jq 2>&1; jq --version 2>&1" 2>&1 | head -10
        return 1
    fi
    
    # Verify JSON payload
    local payload_size=$(kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "wc -c < ${json_payload_temp}" 2>/dev/null || echo "0")
    
    if ! kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "grep -q 'Flamegraph HTML content' ${json_payload_temp}" 2>/dev/null; then
        echo "   ⚠️ Warning: JSON payload may not contain artifact content (marker not found)"
    else
        echo "   ✅ JSON payload verified (${payload_size} bytes, contains artifact marker)"
    fi
    
    # Submit to OpenAI API
    echo "   📡 Sending request to OpenAI API..."
    
    local curl_cmd="curl -s -w '\nHTTP_CODE:%{http_code}' -X POST"
    curl_cmd="${curl_cmd} -H 'Content-Type: application/json'"
    curl_cmd="${curl_cmd} -H 'Authorization: Bearer ${OPENAI_API_KEY}'"
    curl_cmd="${curl_cmd} -d @${json_payload_temp}"
    curl_cmd="${curl_cmd} 'https://api.openai.com/v1/chat/completions'"
    
    local api_response=$(kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "${curl_cmd}" 2>/dev/null || echo "")
    
    # Clean up temp files
    kubectl exec --namespace "${NAMESPACE}" "${jobmanager_pod}" -- \
        sh -c "rm -f ${artifact_file} ${prompt_file} ${json_payload_temp}" 2>/dev/null || true
    
    local http_code=$(echo "$api_response" | grep "HTTP_CODE:" | cut -d: -f2 || echo "")
    local response_body=$(echo "$api_response" | sed '/HTTP_CODE:/d' || echo "")
    
    if [ -z "$http_code" ]; then
        echo "   ⚠️ Could not get HTTP response from OpenAI API"
        if [ -n "$api_response" ]; then
            echo "   Response: $api_response"
        fi
        return 1
    fi
    
    echo "   HTTP Status Code: ${http_code}"
    if [ "$http_code" != "200" ]; then
        echo "   ❌ OpenAI API request failed with status ${http_code}"
        if [ -n "$response_body" ]; then
            echo "   Error response: $response_body"
        fi
        return 1
    fi
    
    echo "   ✅ Analysis request submitted successfully"
    echo ""
    echo "   📊 Analysis Results:"
    
    # Extract the message content from OpenAI response
    local analysis_output=""
    if command -v jq >/dev/null 2>&1; then
        analysis_output=$(echo "$response_body" | jq -r '.choices[0].message.content' 2>/dev/null || echo "$response_body")
    else
        local extracted_content=$(echo "$response_body" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        if [ -n "$extracted_content" ]; then
            analysis_output=$(echo "$extracted_content" | sed 's/\\n/\n/g')
        else
            analysis_output=$(echo "$response_body" | head -50)
        fi
    fi
    
    # Output analysis results
    output_analysis_results "${analysis_output}"
}

# Output analysis results to file or stdout
output_analysis_results() {
    local analysis_output=$1
    
    # If an output directory is requested, generate a filename
    if [ -n "${OUTPUT_DIR}" ]; then
        local timestamp_safe=$(date +%Y%m%d_%H%M%S)
        mkdir -p "${OUTPUT_DIR}" || true
        local output_file_path="${OUTPUT_DIR}/squirrly_analysis_${timestamp_safe}.txt"
        echo "$analysis_output" > "${output_file_path}"
        echo "   📁 Analysis written to ${output_file_path}"
    elif [ -n "${OUTPUT_FILE}" ]; then
        mkdir -p "$(dirname "${OUTPUT_FILE}")" || true
        echo "$analysis_output" > "${OUTPUT_FILE}"
        echo "   📁 Analysis written to ${OUTPUT_FILE}"
    else
        # Default: print to stdout (inline)
        echo "$analysis_output"
    fi
}

# Handle profiler response and process artifacts
handle_profiler_response() {
    local jobmanager_pod=$1
    local deployment_name=$2
    local http_code=$3
    local response_body=$4
    local profiler_start_time=$5
    
    if [ -z "$http_code" ]; then
        echo "   ⚠️ Could not trigger profiler (no HTTP response)"
        return 1
    fi
    
    echo "   HTTP Status Code: ${http_code}"
    if [ "$http_code" != "200" ] && [ "$http_code" != "202" ]; then
        echo "   ❌ Profiler endpoint returned error status: ${http_code}"
        if [ -n "$response_body" ]; then
            echo "   Error response: $response_body"
        fi
        return 1
    fi
    
    echo "   ✅ Profiler triggered successfully"
    if [ -n "$response_body" ]; then
        echo "   Response: $response_body"
        # Check if response contains artifact path information
        if echo "$response_body" | grep -q "path\|file\|artifact"; then
            echo "   📄 Artifact location info in response: $response_body"
        fi
    fi
    
    # Wait for profiler to complete
    echo "   ⏳ Waiting ${PROFILER_DURATION} seconds for profiler to complete..."
    sleep ${PROFILER_DURATION}
    
    # Search for artifacts
    local artifacts_found=$(search_for_artifacts "${deployment_name}" "${profiler_start_time}")
    
    if [ "$artifacts_found" = "true" ] && [ -n "$LATEST_ARTIFACT" ]; then
        # Submit artifact to API for analysis
        case "${API_PROVIDER}" in
            openai)
                if [ -z "$OPENAI_API_KEY" ]; then
                    echo "   ⚠️ OPENAI_API_KEY not configured, skipping analysis"
                else
                    analyze_artifact_with_openai "${jobmanager_pod}" "${ARTIFACT_POD}" "${LATEST_ARTIFACT}"
                fi
                ;;
            *)
                echo "   ⚠️ Unsupported API provider: ${API_PROVIDER}"
                echo "   Supported providers: openai"
                ;;
        esac
    fi
    
    if [ "$artifacts_found" = "true" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Print final summary
print_summary() {
    local artifacts_found=$1
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$artifacts_found" = "true" ]; then
        echo "✅ Profiler run completed successfully at $(date)"
        echo "✅ Profiling artifacts have been generated"
    else
        echo "⚠️ Profiler run completed at $(date)"
        echo "⚠️ No artifacts were found - profiler may have failed or artifacts are in a different location"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Main execution
parse_arguments "$@"

echo "🔬 Squirrly Profiler - $(date)"
echo "=================================="
echo "Target FlinkDeployment: ${FLINK_DEPLOYMENT_NAME}"
echo ""

verify_flink_deployment

DEPLOYMENT_NAME="${FLINK_DEPLOYMENT_NAME}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Processing FlinkDeployment: ${DEPLOYMENT_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

JOBMANAGER_POD=$(get_jobmanager_pod "${DEPLOYMENT_NAME}")
echo "✅ JobManager Pod: ${JOBMANAGER_POD}"

REST_SERVICE="${DEPLOYMENT_NAME}-rest"
REST_URL="http://${REST_SERVICE}:8081"

verify_rest_service "${REST_SERVICE}"

JOB_ID=$(get_job_id "${JOBMANAGER_POD}" "${REST_URL}")
echo "✅ Found running job: ${JOB_ID}"

VERTEX_ID=$(get_vertex_id "${JOBMANAGER_POD}" "${REST_URL}" "${JOB_ID}")
echo "✅ Vertex ID: ${VERTEX_ID}"

TASKMANAGER_ID=$(get_taskmanager_id "${JOBMANAGER_POD}" "${REST_URL}")
echo "   TaskManager ID: ${TASKMANAGER_ID}"

trigger_profiler "${JOBMANAGER_POD}" "${REST_URL}" "${TASKMANAGER_ID}"

ARTIFACTS_FOUND=$(handle_profiler_response \
    "${JOBMANAGER_POD}" \
    "${DEPLOYMENT_NAME}" \
    "${PROFILER_HTTP_CODE}" \
    "${PROFILER_RESPONSE_BODY}" \
    "${PROFILER_START_TIME}")

print_summary "${ARTIFACTS_FOUND}"

