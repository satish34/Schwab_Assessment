FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /workspace

COPY pom.xml ./
RUN mvn --batch-mode --no-transfer-progress dependency:go-offline

COPY src ./src
RUN mvn --batch-mode --no-transfer-progress verify

FROM eclipse-temurin:21.0.11_10-jre-noble
ARG SERVICE_VERSION=dev

RUN groupadd --system --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=build --chown=10001:10001 /workspace/target/app-a-gateway-*.jar /app/app.jar

ENV SERVICE_VERSION=${SERVICE_VERSION}

EXPOSE 8080
USER 10001:10001
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-Djava.io.tmpdir=/tmp", "-jar", "/app/app.jar"]
