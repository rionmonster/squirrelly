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

echo "🔬 Squirrly Profiler - $(date)"
echo "=================================="
echo "Target FlinkDeployment: ${FLINK_DEPLOYMENT_NAME}"
echo ""

# Verify FlinkDeployment exists
if ! kubectl get flinkdeployment ${FLINK_DEPLOYMENT_NAME} -n ${NAMESPACE} > /dev/null 2>&1; then
    echo "❌ FlinkDeployment '${FLINK_DEPLOYMENT_NAME}' not found in namespace ${NAMESPACE}"
    exit 1
fi

DEPLOYMENT_NAME="${FLINK_DEPLOYMENT_NAME}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Processing FlinkDeployment: ${DEPLOYMENT_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get JobManager pod
JOBMANAGER_POD=$(kubectl get pods -n ${NAMESPACE} \
    -l app=${DEPLOYMENT_NAME},component=jobmanager \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$JOBMANAGER_POD" ]; then
    echo "❌ JobManager pod not found for ${DEPLOYMENT_NAME}"
    exit 1
fi

echo "✅ JobManager Pod: ${JOBMANAGER_POD}"

# Get Flink REST service
REST_SERVICE="${DEPLOYMENT_NAME}-rest"
REST_URL="http://${REST_SERVICE}:8081"

# Check if REST service is available
if ! kubectl get service ${REST_SERVICE} -n ${NAMESPACE} > /dev/null 2>&1; then
    echo "❌ REST service ${REST_SERVICE} not found"
    exit 1
fi

# Get job information
echo "🔍 Fetching job information..."
JOB_LIST=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
    curl -s ${REST_URL}/jobs 2>/dev/null || echo "")

if [ -z "$JOB_LIST" ]; then
    echo "❌ Could not retrieve job list from REST API"
    exit 1
fi

# Extract job ID from job list (get the first running job)
JOB_ID=$(echo "$JOB_LIST" | grep -oE '"id":"[a-f0-9]+"' | head -1 | cut -d'"' -f4 || echo "")

if [ -z "$JOB_ID" ]; then
    echo "❌ No running job found for ${DEPLOYMENT_NAME}"
    echo "   Job list response: $JOB_LIST"
    exit 1
fi

echo "✅ Found running job: ${JOB_ID}"

# Get job details to find vertices
echo "🔍 Fetching job details to find vertices..."
JOB_DETAILS=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
    curl -s ${REST_URL}/jobs/${JOB_ID} 2>/dev/null || echo "")

if [ -z "$JOB_DETAILS" ]; then
    echo "❌ Could not retrieve job details"
    exit 1
fi

# Extract vertex ID from job details (get the first vertex/operator)
# Vertices are in the "vertices" array, we want the first one's id
VERTEX_ID=$(echo "$JOB_DETAILS" | grep -oE '"id":"[a-f0-9-]+"' | head -1 | cut -d'"' -f4 || echo "")

if [ -z "$VERTEX_ID" ]; then
    echo "❌ Could not extract vertex ID from job details"
    echo "   Attempting to find vertices in response..."
    echo "$JOB_DETAILS" | grep -i "vertex\|operator" | head -5
    exit 1
fi

echo "✅ Vertex ID: ${VERTEX_ID}"

# Initialize artifact tracking
ARTIFACTS_FOUND=false

# Trigger profiler
echo ""
echo "🔬 Triggering Flink Profiler..."
echo "   Type: ${PROFILER_TYPE}"
echo "   Duration: ${PROFILER_DURATION} seconds"

# Get TaskManager ID (use the first available TaskManager)
TASKMANAGER_ID=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
    curl -s ${REST_URL}/taskmanagers 2>/dev/null | \
    grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4 || echo "")

if [ -z "$TASKMANAGER_ID" ]; then
    echo "   ❌ Could not find TaskManager ID"
    exit 1
fi

echo "   TaskManager ID: ${TASKMANAGER_ID}"
echo "   Endpoint: ${REST_URL}/taskmanagers/${TASKMANAGER_ID}/profiler"

# Capture timestamp before triggering profiler to identify the artifact
PROFILER_START_TIME=$(date +"%Y-%m-%d_%H_%M_%S")
echo "   Profiler run timestamp: ${PROFILER_START_TIME}"

# Trigger profiler on TaskManager (endpoint expects JSON body, not query params)
PROFILER_ENDPOINT="${REST_URL}/taskmanagers/${TASKMANAGER_ID}/profiler"
PROFILER_JSON="{\"mode\":\"${PROFILER_TYPE}\",\"duration\":${PROFILER_DURATION}}"

PROFILER_RESPONSE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
    curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "${PROFILER_JSON}" \
    "${PROFILER_ENDPOINT}" \
    2>/dev/null || echo "")

HTTP_CODE=$(echo "$PROFILER_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2 || echo "")
RESPONSE_BODY=$(echo "$PROFILER_RESPONSE" | sed '/HTTP_CODE:/d' || echo "")

if [ -n "$HTTP_CODE" ]; then
    echo "   HTTP Status Code: ${HTTP_CODE}"
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ]; then
        echo "   ✅ Profiler triggered successfully"
        if [ -n "$RESPONSE_BODY" ]; then
            echo "   Response: $RESPONSE_BODY"
            # Check if response contains artifact path information
            if echo "$RESPONSE_BODY" | grep -q "path\|file\|artifact"; then
                echo "   📄 Artifact location info in response: $RESPONSE_BODY"
            fi
        fi
        
        # Wait for profiler to complete
        echo "   ⏳ Waiting ${PROFILER_DURATION} seconds for profiler to complete..."
        sleep ${PROFILER_DURATION}
        
        # Check for profiler artifacts on TaskManager pods using filesystem search
        echo ""
        echo "   📦 Checking for profiler artifacts on TaskManager pods..."
        
        # Get TaskManager pods
        TASKMANAGER_PODS=$(kubectl get pods -n ${NAMESPACE} \
            -l app=${DEPLOYMENT_NAME},component=taskmanager \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [ -z "$TASKMANAGER_PODS" ]; then
            echo "   ⚠️ No TaskManager pods found"
            ARTIFACTS_FOUND=false
        else
            ARTIFACTS_FOUND=false
            MAX_RETRIES=12  # Poll for up to 60 seconds (12 * 5 seconds)
            RETRY_INTERVAL=5
            TIMESTAMP_DATE=$(echo "${PROFILER_START_TIME}" | cut -d'_' -f1)  # YYYY-MM-DD
            
            for RETRY in $(seq 1 ${MAX_RETRIES}); do
                ARTIFACT_COUNT=0
                for TM_POD in $TASKMANAGER_PODS; do
                    # Search for artifacts matching our timestamp
                    # Pattern: *<PROFILER_TYPE>_<TIMESTAMP_DATE>_*.html
                    # Use configured output directories or default locations
                    SEARCH_DIRS=$(echo "${PROFILER_OUTPUT_DIR}" | tr ' ' '\n' | tr '\n' ' ')
                    FIND_CMD="find ${SEARCH_DIRS} -type f \
                        \( -name '*${PROFILER_TYPE}_${TIMESTAMP_DATE}_*.html' -o \
                           -name '*${PROFILER_TYPE}*.html' \) \
                        2>/dev/null | sort -r | head -5"
                    
                    ARTIFACTS=$(kubectl exec -n ${NAMESPACE} ${TM_POD} -- \
                        sh -c "${FIND_CMD}" 2>/dev/null || echo "")
                    
                    if [ -n "$ARTIFACTS" ]; then
                        ARTIFACT_LIST=$(echo "$ARTIFACTS" | grep -v '^$' || echo "")
                        if [ -n "$ARTIFACT_LIST" ]; then
                            # Get the most recent artifact (first in sorted list)
                            LATEST_ARTIFACT=$(echo "$ARTIFACT_LIST" | head -1)
                            
                            if [ -n "$LATEST_ARTIFACT" ]; then
                                if [ "$ARTIFACTS_FOUND" = "false" ]; then
                                    echo "   ✅ Found profiler artifact!"
                                    ARTIFACTS_FOUND=true
                                fi
                                
                                # Get file info for the latest artifact
                                FILE_INFO=$(kubectl exec -n ${NAMESPACE} ${TM_POD} -- \
                                    sh -c "stat -c'%s|%y' '$LATEST_ARTIFACT' 2>/dev/null || stat -f'%z|%Sm' '$LATEST_ARTIFACT' 2>/dev/null || echo 'unknown|unknown'" 2>/dev/null || echo "unknown|unknown")
                                SIZE=$(echo "$FILE_INFO" | cut -d'|' -f1)
                                MTIME=$(echo "$FILE_INFO" | cut -d'|' -f2)
                                
                                MATCH_INDICATOR=""
                                if echo "$LATEST_ARTIFACT" | grep -q "${TIMESTAMP_DATE}"; then
                                    MATCH_INDICATOR=" ⭐ (matches this run)"
                                fi
                                
                                echo "   🎯 Artifact for this run:"
                                echo "      Path: ${LATEST_ARTIFACT}${MATCH_INDICATOR}"
                                echo "      Size: ${SIZE} bytes"
                                echo "      Modified: ${MTIME}"
                                ARTIFACT_COUNT=1
                            fi
                        fi
                    fi
                done
                
                if [ "$ARTIFACTS_FOUND" = "true" ]; then
                    echo ""
                    echo "   ✅ Profiler completed successfully! Artifacts generated."
                    
                    # Submit artifact to API for analysis
                    if [ -n "$LATEST_ARTIFACT" ]; then
                        echo ""
                        echo "   📤 Submitting artifact to ${API_PROVIDER} for analysis..."
                        
                        # Validate API provider and required credentials
                        case "${API_PROVIDER}" in
                            openai)
                                if [ -z "$OPENAI_API_KEY" ]; then
                                    echo "   ⚠️ OPENAI_API_KEY not configured, skipping analysis"
                                else
                                    # Read prompt from file
                                    if [ ! -f "${ANALYSIS_PROMPT_FILE}" ]; then
                                        echo "   ⚠️ Prompt file not found: ${ANALYSIS_PROMPT_FILE}"
                                    else
                                        ANALYSIS_PROMPT=$(cat "${ANALYSIS_PROMPT_FILE}")
                                        
                                        # Read artifact content directly from TaskManager pod and write to JobManager pod
                                        # This avoids shell variable size limits
                                        ARTIFACT_FILE="/tmp/profiler_artifact_$(date +%s).html"
                                        PROMPT_FILE="/tmp/profiler_prompt_$(date +%s).txt"
                                        JSON_PAYLOAD_TEMP="/tmp/profiler_api_$(date +%s).json"
                                        
                                        # Get artifact size for verification
                                        ARTIFACT_SIZE=$(kubectl exec -n ${NAMESPACE} ${TM_POD} -- \
                                            sh -c "wc -c < ${LATEST_ARTIFACT}" 2>/dev/null || echo "0")
                                        
                                        if [ "$ARTIFACT_SIZE" = "0" ] || [ -z "$ARTIFACT_SIZE" ]; then
                                            echo "   ⚠️ Could not read artifact size from ${TM_POD}:${LATEST_ARTIFACT}"
                                            continue
                                        fi
                                        
                                        echo "   📊 Artifact size: ${ARTIFACT_SIZE} bytes"
                                        
                                        # Copy artifact directly from TaskManager to JobManager pod
                                        # Use kubectl cp or direct cat through pipe to avoid shell variable limits
                                        kubectl exec -n ${NAMESPACE} ${TM_POD} -- \
                                            cat "${LATEST_ARTIFACT}" 2>/dev/null | \
                                            kubectl exec -i -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "cat > ${ARTIFACT_FILE}" 2>/dev/null || {
                                                echo "   ⚠️ Failed to copy artifact content to JobManager pod"
                                                continue
                                            }
                                        
                                        # Verify artifact was written correctly
                                        VERIFIED_SIZE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "wc -c < ${ARTIFACT_FILE}" 2>/dev/null || echo "0")
                                        
                                        if [ "$VERIFIED_SIZE" != "$ARTIFACT_SIZE" ]; then
                                            echo "   ⚠️ Artifact size mismatch! Expected: ${ARTIFACT_SIZE}, Got: ${VERIFIED_SIZE}"
                                            continue
                                        fi
                                        
                                        echo "   ✅ Artifact copied successfully (${VERIFIED_SIZE} bytes verified)"
                                        
                                        # Write prompt to file
                                        echo "$ANALYSIS_PROMPT" | kubectl exec -i -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "cat > ${PROMPT_FILE}" 2>/dev/null || {
                                                echo "   ⚠️ Failed to write prompt to JobManager pod"
                                                continue
                                            }
                                        
                                        # Build OpenAI API JSON payload using jq
                                        # Use -Rs (raw input, slurp) to read stdin as a single string
                                        # The input is available as . (dot) in the jq expression
                                        echo "   🔨 Building JSON payload..."
                                        if ! kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "PROMPT=\$(cat ${PROMPT_FILE}); ARTIFACT=\$(cat ${ARTIFACT_FILE}); echo -e \"\${PROMPT}\n\nFlamegraph HTML content:\n\${ARTIFACT}\" | jq -Rs '{model: \"gpt-4o\", messages: [{role: \"user\", content: .}], temperature: 0.7, max_tokens: 2000}' > ${JSON_PAYLOAD_TEMP}" 2>&1; then
                                            echo "   ⚠️ Failed to build API payload with jq"
                                            echo "   Debug: Checking if files exist and jq is available..."
                                            kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                                sh -c "ls -lh ${PROMPT_FILE} ${ARTIFACT_FILE} 2>&1; command -v jq 2>&1; jq --version 2>&1" 2>&1 | head -10
                                            continue
                                        fi
                                        
                                        # Verify JSON payload contains artifact content
                                        PAYLOAD_SIZE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "wc -c < ${JSON_PAYLOAD_TEMP}" 2>/dev/null || echo "0")
                                        
                                        # Check if payload contains "Flamegraph HTML content" marker
                                        if ! kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "grep -q 'Flamegraph HTML content' ${JSON_PAYLOAD_TEMP}" 2>/dev/null; then
                                            echo "   ⚠️ Warning: JSON payload may not contain artifact content (marker not found)"
                                        else
                                            echo "   ✅ JSON payload verified (${PAYLOAD_SIZE} bytes, contains artifact marker)"
                                        fi
                                        
                                        # Submit to OpenAI API using curl from JobManager pod
                                        echo "   📡 Sending request to OpenAI API..."
                                        
                                        CURL_CMD="curl -s -w '\nHTTP_CODE:%{http_code}' -X POST"
                                        CURL_CMD="${CURL_CMD} -H 'Content-Type: application/json'"
                                        CURL_CMD="${CURL_CMD} -H 'Authorization: Bearer ${OPENAI_API_KEY}'"
                                        CURL_CMD="${CURL_CMD} -d @${JSON_PAYLOAD_TEMP}"
                                        CURL_CMD="${CURL_CMD} 'https://api.openai.com/v1/chat/completions'"
                                        
                                        API_RESPONSE=$(kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "${CURL_CMD}" 2>/dev/null || echo "")
                                        
                                        # Clean up temp files
                                        kubectl exec -n ${NAMESPACE} ${JOBMANAGER_POD} -- \
                                            sh -c "rm -f ${ARTIFACT_FILE} ${PROMPT_FILE} ${JSON_PAYLOAD_TEMP}" 2>/dev/null || true
                                        
                                        HTTP_CODE=$(echo "$API_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2 || echo "")
                                        RESPONSE_BODY=$(echo "$API_RESPONSE" | sed '/HTTP_CODE:/d' || echo "")
                                        
                                        if [ -n "$HTTP_CODE" ]; then
                                            echo "   HTTP Status Code: ${HTTP_CODE}"
                                            if [ "$HTTP_CODE" = "200" ]; then
                                                echo "   ✅ Analysis request submitted successfully"
                                                echo ""
                                                echo "   📊 Analysis Results:"
                                                # Extract the message content from OpenAI response
                                                if command -v jq >/dev/null 2>&1; then
                                                    echo "$RESPONSE_BODY" | jq -r '.choices[0].message.content' 2>/dev/null || echo "$RESPONSE_BODY"
                                                else
                                                    # Try to extract content using grep/sed if jq not available
                                                    EXTRACTED_CONTENT=$(echo "$RESPONSE_BODY" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
                                                    if [ -n "$EXTRACTED_CONTENT" ]; then
                                                        echo "$EXTRACTED_CONTENT" | sed 's/\\n/\n/g'
                                                    else
                                                        echo "$RESPONSE_BODY" | head -50
                                                    fi
                                                fi
                                            else
                                                echo "   ❌ OpenAI API request failed with status ${HTTP_CODE}"
                                                if [ -n "$RESPONSE_BODY" ]; then
                                                    echo "   Error response: $RESPONSE_BODY"
                                                fi
                                            fi
                                        else
                                            echo "   ⚠️ Could not get HTTP response from OpenAI API"
                                            if [ -n "$API_RESPONSE" ]; then
                                                echo "   Response: $API_RESPONSE"
                                            fi
                                        fi
                                    fi
                                fi
                                ;;
                            *)
                                echo "   ⚠️ Unsupported API provider: ${API_PROVIDER}"
                                echo "   Supported providers: openai"
                                ;;
                        esac
                    fi
                    
                    break
                fi
                
                if [ $RETRY -lt ${MAX_RETRIES} ]; then
                    echo "   ⏳ Artifacts not ready yet, retrying in ${RETRY_INTERVAL} seconds... (attempt ${RETRY}/${MAX_RETRIES})"
                    sleep ${RETRY_INTERVAL}
                fi
            done
            
            if [ "$ARTIFACTS_FOUND" = "false" ]; then
                echo "   ⚠️ No profiler artifacts found after ${MAX_RETRIES} attempts (${MAX_RETRIES} * ${RETRY_INTERVAL}s)"
                echo "   Note: Artifacts may be in a different location or not yet generated"
            fi
        fi
    else
        echo "   ❌ Profiler endpoint returned error status: ${HTTP_CODE}"
        if [ -n "$RESPONSE_BODY" ]; then
            echo "   Error response: $RESPONSE_BODY"
        fi
    fi
else
    echo "   ⚠️ Could not trigger profiler (no HTTP response)"
    if [ -n "$PROFILER_RESPONSE" ]; then
        echo "   Response: $PROFILER_RESPONSE"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$ARTIFACTS_FOUND" = "true" ]; then
    echo "✅ Profiler run completed successfully at $(date)"
    echo "✅ Profiling artifacts have been generated"
else
    echo "⚠️ Profiler run completed at $(date)"
    echo "⚠️ No artifacts were found - profiler may have failed or artifacts are in a different location"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

