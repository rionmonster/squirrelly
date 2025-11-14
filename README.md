# Squirrly - AI-Boosted Profiling for Apache Flink on Kubernetes

Squirrly is currently a work in progress that aims to provide a pattern for leveraging the existing profiling mechanisms in conjunction with AI tooling to identify and address potential bottlenecks within running jobs.

## Overview

This project contains a minimal Flink streaming job that performs a series:
- Generates random integers (1-100) continuously
- Processes them through a map function (multiplies by 2 and adds 10)
- Writes the results to a DiscardingSink

The job is packaged and deployed to Kubernetes with a single command, making local development and testing straightforward.

## Prerequisites

Before running this project, ensure you have the following tools installed:

1. **Java 21** - Required for building and running the Flink job
   ```bash
   java -version
   ```
   
   **Note:** Make sure Maven is using Java 21. If you have multiple Java versions installed, you may need to set `JAVA_HOME`:
   ```bash
   export JAVA_HOME=$(/usr/libexec/java_home -v 21)
   mvn --version  # Verify Maven is using Java 21
   ```

2. **Maven** - Build tool
   ```bash
   mvn --version
   ```

3. **Docker** - For building container images
   ```bash
   docker --version
   ```

4. **Minikube** - Local Kubernetes cluster
   ```bash
   minikube version
   ```

5. **kubectl** - Kubernetes command-line tool
   ```bash
   kubectl version --client
   ```

## Installation

1. **Start Minikube**
   ```bash
   minikube start
   ```

2. **Verify Minikube is running**
   ```bash
   minikube status
   ```

## Running the Job

Deploy the Flink job to Kubernetes with a single command:

```bash
./deploy.sh
```

This script will:
1. Build the Kotlin Flink job
2. Create the `squirrly` namespace in Kubernetes
3. Deploy Flink JobManager and TaskManager
4. Copy the JAR to both pods
5. Submit the Flink job
6. Set up port forwarding for the Flink UI

After deployment, the Flink UI will be available at:
- **http://localhost:8081**

## Project Structure

```
squirrly/
├── src/main/kotlin/dev/squirrly/
│   └── SimpleFlinkJob.kt                 # Main Flink streaming job
├── k8s/
│   ├── namespace.yaml                    # Kubernetes namespace
│   ├── jobmanager-deployment.yaml        # Flink JobManager deployment
│   ├── jobmanager-service.yaml           # Flink JobManager service
│   └── taskmanager-deployment.yaml       # Flink TaskManager deployment
├── pom.xml                               # Maven build configuration
├── Dockerfile                            # Docker image definition
├── deploy.sh                             # Deployment script
└── README.md                             # This file
```

## Monitoring

Once deployed, you can monitor the Flink job through the **Flink Web UI** at http://localhost:8081.

## Cleanup

To remove all resources:

```bash
kubectl delete namespace squirrly
```

To stop minikube:

```bash
minikube stop
```





