# App A gateway

App A validates `POST /v1/risk`, forwards it to the local App B service, and
returns App B's deterministic result. Its liveness and readiness checks never
call App B; `/health/cell` reads only the background evaluation probe's cached
state.

Required runtime values are `RISK_REGION`, `RISK_CLUSTER`, `SERVICE_VERSION`,
and `APP_B_BASE_URL`. The service listens on port `8080`.

Run locally with the repository's pinned Maven image:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace/apps/app-a-java \
  maven:3.9.11-eclipse-temurin-21 mvn verify
```
