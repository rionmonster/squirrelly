FROM flink:2.0.1-scala_2.12-java21

# Install jq for JSON processing (required by profiler)
RUN apt-get update && \
    apt-get install -y jq && \
    rm -rf /var/lib/apt/lists/*

# Copy the built JAR to the Flink lib directory
COPY target/sample-job.jar /opt/flink/lib/

# Use the default Flink entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["standalone-job"]

