#!/bin/sh
set -eu

case "${CLOUD_PROFILER_ENABLED:-false}" in
  true)
    exec java \
      -XX:MaxRAMPercentage=75.0 \
      -Djava.io.tmpdir=/tmp \
      "-agentpath:/opt/cprof/profiler_java_agent.so=-cprof_service=app-a-gateway,-cprof_service_version=${SERVICE_VERSION},-cprof_enable_heap_sampling=true,-logtostderr,-minloglevel=2" \
      -jar /app/app.jar
    ;;
  false)
    ;;
  *)
    echo "CLOUD_PROFILER_ENABLED must be true or false" >&2
    exit 64
    ;;
esac

exec java \
  -XX:MaxRAMPercentage=75.0 \
  -Djava.io.tmpdir=/tmp \
  -jar /app/app.jar
