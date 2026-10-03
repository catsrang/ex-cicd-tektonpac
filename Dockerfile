# Runtime-only image: the jar is built beforehand (`mvn package`, or the
# pipeline's Maven task) and must exist in the build context under target/.
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:latest
WORKDIR /deployments
COPY target/demo-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
