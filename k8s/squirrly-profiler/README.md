# Squirrelly Profiler

The Squirrelly Profiler is a one-off Kubernetes Job that discovers FlinkDeployments, triggers the Flink Profiler, and retrieves profiler artifacts.

![Squirrelly Flow](../../images/squirrelly-flow.png)

## Deployment

Deploy shared infrastructure resources first (if not already deployed):

```bash
kubectl apply -f k8s/resources/
```

The profiler script (`profiler.sh`) is the single source of truth. The ConfigMap is automatically generated from it when you run the profiler script. To manually create/update the ConfigMap:

```bash
kubectl create configmap squirrelly-profiler-script \
    --from-file=profiler.sh=k8s/squirrelly-profiler/profiler.sh \
    --namespace=squirrelly \
    --dry-run=client -o yaml | kubectl apply -f -
```

## Running the Profiler

**Recommended:** Use the helper script:

```bash
./scripts/run-profiler.sh
```

### Command-Line Options

The `run-profiler.sh` script supports the following options:

- `-o, --output FILE` - Save profiler output to the specified file
- `--inline` - Display output inline to terminal (this is the default behavior)
- `-h, --help` - Show help message with usage information

**Examples:**

```bash
# Display output inline (default)
./scripts/run-profiler.sh

# Explicitly request inline output
./scripts/run-profiler.sh --inline

# Save output to a file
./scripts/run-profiler.sh -o profiler.log

# Save output to a specific directory with timestamp
./scripts/run-profiler.sh --output ./logs/profiler-$(date +%Y%m%d).log

# Show help
./scripts/run-profiler.sh --help
```

**Note:** When using `--output` or `-o`, the script will wait for the profiler job to complete before saving all logs to the file. When using `--inline` (default), the script follows logs in real-time using `kubectl logs -f`.

**Manual options:**

1. Delete and recreate:
```bash
# Delete existing job
kubectl delete job squirrelly-profiler --namespace squirrelly

# Create new job
kubectl apply -f k8s/squirrelly-profiler/job.yaml

# Watch the logs
kubectl logs --namespace squirrelly -f job/squirrelly-profiler
```

2. Create a new job:
```bash
# Create a new job instance
kubectl create job --from=job/squirrelly-profiler squirrelly-profiler-$(date +%Y%m%d-%H%M%S) --namespace squirrelly

# Follow logs
kubectl logs --namespace squirrelly -f job/squirrelly-profiler-<timestamp>
```

## Configuration

The profiler can be configured via environment variables in the Job:

- `FLINK_DEPLOYMENT_NAME`: Name of the FlinkDeployment to profile - default: sample-job
- `PROFILER_TYPE`: Type of profiler (CPU, ITIMER, or ALLOC) - default: ITIMER
- `PROFILER_DURATION`: Duration in seconds - default: 60
- `NAMESPACE`: Namespace to monitor - default: squirrelly
- `PROFILER_OUTPUT_DIR`: Space-separated list of directories to search for profiler artifacts - default: "/tmp /opt/flink/log /opt/flink"
- `API_PROVIDER`: API provider for analysis - default: "openai" (may add additional ones later)
- `OPENAI_API_KEY`: OpenAI API key for analysis (can be set from local environment when running `run-profiler.sh`)
- `ANALYSIS_PROMPT_FILE`: Path to prompt file - default: "/scripts/prompt.md"

The analysis prompt is stored in `k8s/squirrelly-profiler/prompt.md` and can be edited separately from the profiler script. 

## Analysis

Analysis is **always performed** when a profiler artifact is found and the API key is configured. The profiler will:

1. Read the prompt from `prompt.md`
2. Read the artifact HTML content from the TaskManager pod
3. Submit both to the configured API provider (currently OpenAI)
4. Display the analysis results in the profiler logs

To enable analysis, set the `OPENAI_API_KEY` environment variable when running the profiler:

```bash
# With inline output (default)
OPENAI_API_KEY=your-key-here ./scripts/run-profiler.sh

# With file output
OPENAI_API_KEY=your-key-here ./scripts/run-profiler.sh -o analysis.log
```

The script supports multiple API providers via the `API_PROVIDER` environment variable. Currently only `openai` is supported, but the architecture allows for easy extension to other providers.

To change configuration, edit the Job:

```bash
kubectl edit job squirrelly-profiler --namespace squirrelly
```

## What It Does

1. Targets a specific FlinkDeployment by name (configured via `FLINK_DEPLOYMENT_NAME`)
2. For the deployment:
   - Finds the JobManager pod
   - Retrieves running job information via REST API
   - Triggers the Flink Profiler on the TaskManager
   - Waits for profiler to complete
   - Finds the profiler artifact matching this run
   - Submits artifact and prompt to API provider for analysis
   - Displays analysis results in the logs

## RBAC

The profiler uses the same ServiceAccount (`squirrelly-service-account`) and RBAC permissions as the Flink job. The `squirrelly-role` Role includes:
- Read access to FlinkDeployments
- Read access to pods and services
- Exec access to pods (to retrieve artifacts and call REST API)

All permissions are scoped to the `squirrelly` namespace.
