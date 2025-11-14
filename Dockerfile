FROM flink:2.0.1-scala_2.12-java21

# Copy the built JAR to the Flink lib directory
COPY target/squirrly-1.0.0.jar /opt/flink/lib/

# Use the default Flink entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["standalone-job"]

