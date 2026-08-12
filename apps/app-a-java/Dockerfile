FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /workspace

COPY pom.xml ./
RUN mvn --batch-mode --no-transfer-progress dependency:go-offline

COPY src ./src
RUN mvn --batch-mode --no-transfer-progress verify

FROM eclipse-temurin:21.0.11_10-jre-noble
ARG SERVICE_VERSION=dev
ARG CLOUD_PROFILER_AGENT_VERSION=20241028_RC00
ARG CLOUD_PROFILER_AGENT_SHA256=509b87c406b59424cb101d561567cadad97d3fd1c235224bca2a114d4a7bde0c

RUN groupadd --system --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && mkdir --parents /opt/cprof \
    && curl --fail --location --show-error --silent \
      "https://storage.googleapis.com/cloud-profiler/java/cloud-profiler-java-agent_${CLOUD_PROFILER_AGENT_VERSION}.tar.gz" \
      --output /tmp/cloud-profiler-agent.tar.gz \
    && echo "${CLOUD_PROFILER_AGENT_SHA256}  /tmp/cloud-profiler-agent.tar.gz" | sha256sum --check --strict \
    && tar --extract --gzip --file /tmp/cloud-profiler-agent.tar.gz --directory /opt/cprof \
    && chmod --recursive a=rX /opt/cprof \
    && rm --force /tmp/cloud-profiler-agent.tar.gz \
    && apt-get purge --yes --auto-remove curl \
    && rm --recursive --force /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build --chown=10001:10001 /workspace/target/app-a-gateway-*.jar /app/app.jar
COPY --chown=10001:10001 docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod 0555 /app/docker-entrypoint.sh

ENV SERVICE_VERSION=${SERVICE_VERSION}
ENV CLOUD_PROFILER_ENABLED=false

EXPOSE 8080
USER 10001:10001
ENTRYPOINT ["/app/docker-entrypoint.sh"]
