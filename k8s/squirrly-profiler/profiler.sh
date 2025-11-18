#!/bin/bash

set -e

NAMESPACE="${NAMESPACE:-squirrly}"
FLINK_DEPLOYMENT_NAME="${FLINK_DEPLOYMENT_NAME:-sample-job}"  # Name of the FlinkDeployment to profile
PROFILER_TYPE="${PROFILER_TYPE:-ITIMER}"      # CPU, ITIMER, or ALLOC
PROFILER_DURATION="${PROFILER_DURATION:-60}"  # Duration in seconds
ENABLE_PROFILER="${ENABLE_PROFILER:-true}"
PROFILER_OUTPUT_DIR="${PROFILER_OUTPUT_DIR:-/tmp /opt/flink/log /opt/flink}"  # Directories to search for profiler artifacts (space-separated)

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

# Trigger profiler if enabled
if [ "$ENABLE_PROFILER" = "true" ]; then
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
                            echo "   📤 TODO: Upload artifacts to LLM du jour for analysis"
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
    else
        echo "ℹ️ Profiler triggering is disabled (ENABLE_PROFILER=false)"
    fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$ENABLE_PROFILER" = "true" ] && [ "$ARTIFACTS_FOUND" = "true" ]; then
    echo "✅ Profiler run completed successfully at $(date)"
    echo "✅ Profiling artifacts have been generated"
elif [ "$ENABLE_PROFILER" = "true" ]; then
    echo "⚠️ Profiler run completed at $(date)"
    echo "⚠️ No artifacts were found - profiler may have failed or artifacts are in a different location"
else
    echo "✅ Profiler run completed at $(date)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

