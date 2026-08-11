# App A exchange-rate gateway

App A serves a static demo UI at `GET /` and a no-input JSON API at
`GET /api/exchange-rates`. The API calls only the cell-local App B endpoint at
`GET /internal/exchange-rates` and returns its deterministic ten-snapshot
synthetic rate catalog unchanged.

Both UI and API responses use `Cache-Control: no-store`. The browser also uses
`cache: "no-store"` when it loads rates. The page and payload state clearly
that the values are synthetic and not for financial use.

The page shows snapshot 1 after its automatic request. Every **Refresh rates**
click makes another no-input `GET`, then advances a browser-local index through
the ten snapshots and wraps back to snapshot 1. No selection is sent to the
services, and no pod stores demo state.

Liveness and readiness never call App B. `/health/cell` reads the cached result
of the background probe, which uses the same internal exchange-rate endpoint.
The 500 ms connect timeout, 750 ms response timeout, one bounded retry, circuit
breaker, and 3-failure/5-success health hysteresis are unchanged.

Runtime values are `SERVICE_REGION`, `SERVICE_CLUSTER`, `SERVICE_VERSION`, and
`APP_B_BASE_URL`. Deployed Pods also use `APP_B_AUTH_MODE=google-id-token` and
`APP_B_TOKEN_AUDIENCE=https://app-b-engine.schwab-assessment.internal`. App A
gets a short-lived Google-signed ID token from the GKE metadata server, caches
it, and sends it as a bearer token on every App B request. Local Compose sets
the authentication mode to `disabled` explicitly with the `local` Spring
profile; startup rejects disabled mode under any other profile. Metadata calls
have a separate three-second timeout and one bounded retry. The service listens
on port `8080`.

Every response sets `nosniff`, frame denial, and a hash-based CSP with no
`unsafe-inline`. HSTS is emitted only when the servlet request is secure or the
trusted forwarding headers identify the original request as HTTPS, so local
HTTP development remains usable.

From the repository root, run the pinned Maven verification:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace/apps/app-a-java \
  maven:3.9.11-eclipse-temurin-21 \
  mvn --batch-mode --no-transfer-progress spotless:check verify
```

When App B is available locally, open `http://127.0.0.1:8080/` or call:

```bash
curl --fail-with-body http://127.0.0.1:8080/api/exchange-rates
```
