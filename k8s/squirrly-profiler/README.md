# Squirrly Profiler

The Squirrly Profiler is a one-off Kubernetes Job that discovers FlinkDeployments, triggers the Flink Profiler, and retrieves profiler artifacts.

## Deployment

Deploy shared infrastructure resources first (if not already deployed):

```bash
kubectl apply -f k8s/resources/
```

The profiler script (`profiler.sh`) is the single source of truth. The ConfigMap is automatically generated from it when you run the profiler script. To manually create/update the ConfigMap:

```bash
kubectl create configmap squirrly-profiler-script \
    --from-file=profiler.sh=k8s/squirrly-profiler/profiler.sh \
    --namespace=squirrly \
    --dry-run=client -o yaml | kubectl apply -f -
```

## Running the Profiler

**Recommended:** Use the helper script:

```bash
./scripts/run-profiler.sh
```

**Manual options:**

1. Delete and recreate:
```bash
# Delete existing job
kubectl delete job squirrly-profiler -n squirrly

# Create new job
kubectl apply -f k8s/squirrly-profiler/job.yaml

# Watch the logs
kubectl logs -n squirrly -f job/squirrly-profiler
```

2. Create a new job:
```bash
# Create a new job instance
kubectl create job --from=job/squirrly-profiler squirrly-profiler-$(date +%Y%m%d-%H%M%S) -n squirrly

# Follow logs
kubectl logs -n squirrly -f job/squirrly-profiler-<timestamp>
```

## Configuration

The profiler can be configured via environment variables in the Job:

- `FLINK_DEPLOYMENT_NAME`: Name of the FlinkDeployment to profile - default: sample-job
- `PROFILER_TYPE`: Type of profiler (CPU, ITIMER, or ALLOC) - default: ITIMER
- `PROFILER_DURATION`: Duration in seconds - default: 60
- `ENABLE_PROFILER`: Enable/disable profiler triggering - default: true
- `NAMESPACE`: Namespace to monitor - default: squirrly
- `PROFILER_OUTPUT_DIR`: Space-separated list of directories to search for profiler artifacts - default: "/tmp /opt/flink/log /opt/flink"

To change configuration, edit the Job:

```bash
kubectl edit job squirrly-profiler -n squirrly
```

## What It Does

1. Targets a specific FlinkDeployment by name (configured via `FLINK_DEPLOYMENT_NAME`)
2. For the deployment:
   - Finds the JobManager pod
   - Retrieves running job information via REST API
   - Triggers the Flink Profiler on the first vertex
   - Waits for profiler to complete
   - Checks for profiler artifacts
   - (TODO: Upload artifacts to LLM du jour for further analysis)

## RBAC

The profiler uses the same ServiceAccount (`squirrly-service-account`) and RBAC permissions as the Flink job. The `squirrly-role` Role includes:
- Read access to FlinkDeployments
- Read access to pods and services
- Exec access to pods (to retrieve artifacts and call REST API)

All permissions are scoped to the `squirrly` namespace.

## Future: Monitor CronJob

A separate `squirrly-monitor` CronJob can be added later to automatically run the profiler on a schedule.
