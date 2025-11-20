You are an experienced Apache Flink engineer. Analyze the performance of this Flink job using the provided profiler HTML flamegraphs (ITIMER, wall-clock, etc.) captured under representative load.

## 1. Key Bottlenecks (Ranked)
Identify the most significant hotspots in the flamegraph (operators, serializers, RocksDB calls, user functions, blocking operations, heavy allocations, etc.).

For each hotspot, briefly state:
- **Where it is**
- **How large it appears**
- **Why it matters** for throughput or resource usage

## 2. Root Causes
For each bottleneck, provide the most likely underlying cause, such as:
- Inefficient serialization/deserialization
- Excessive object creation or GC pressure
- Blocking I/O or synchronous operations
- Expensive parsing or transformations
- RocksDB or state-backend overhead
- Misconfigured parallelism or operator chaining

## 3. Actionable Recommendations (Ranked)
For each recommendation, include:
- **Proposed change** (code, config, architecture)
- **Why it helps** (reduces CPU, GC, latency, backpressure, etc.)
- **Impact estimate** (high / medium / low)
- **Trade-offs or considerations**

## 4. Additional Observations
List any secondary or emerging issues visible in the flamegraph that may not be critical now but could become problematic at higher load or scale.