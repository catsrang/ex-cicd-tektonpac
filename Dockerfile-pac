# --- Build stage ---
FROM registry.access.redhat.com/ubi9/openjdk-17:latest AS build
WORKDIR /build
COPY pom.xml .
COPY src ./src
USER root
RUN mvn -B -DskipTests package

# --- Runtime stage ---
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:latest
WORKDIR /deployments
COPY --from=build /build/target/demo-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
