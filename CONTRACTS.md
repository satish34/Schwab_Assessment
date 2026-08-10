# Frozen cross-layer contracts

Any verified change to a value in this file must update all consumers in the
same change.

## Architecture

- Public routing: one Terraform-managed global external Application Load
  Balancer using `EXTERNAL_MANAGED`, one backend service, and six standalone
  zonal GKE pod NEGs.
- Regional model: `us-central1` and `us-east4` are independent, active-active
  cells. Neither is a strict traffic primary.
- Internal call: App A calls only the local
  `app-b-engine.risk-system.svc.cluster.local` ClusterIP.
- Cell failover: App A's background exchange-rate probe controls cached
  `/health/cell` state. Kubernetes readiness never depends on App B.
- Observability: Cloud Logging to partitioned BigQuery for application panels;
  Cloud Monitoring for restart and utilization panels.

## Resource names

The live foundation was created before the application changed from a risk
example to a currency-rate demo. Existing `risk-*` cloud, network, namespace,
dataset, and registry identifiers remain stable technical names; renaming them
would replace or migrate healthy infrastructure and is outside this application
release.

| Contract | Value |
|---|---|
| Namespace | `risk-system` |
| Regions | `us-central1`, `us-east4` |
| Cluster names | `gke-risk-usc1`, `gke-risk-use4` |
| Kubernetes Services | `app-a-gateway`, `app-b-engine` |
| Container port | `8080` for both applications |
| NEG names | `app-a-neg-usc1`, `app-a-neg-use4` |
| Artifact Registry | `us-central1-docker.pkg.dev/PROJECT_ID/risk` |
| BigQuery dataset | `risk_logs` in `US` |
| Expected BigQuery log table | `stdout`, verified after first export |
| Backend service | `risk-app-a-gateway-backend` |
| Global address | `risk-global-ip` |
| Cluster node service accounts | `risk-gke-usc1-nodes`, `risk-gke-use4-nodes` |
| Optional TLS objects | `risk-dns-auth`, `risk-cert`, `risk-cert-map` |
| Health firewall | `risk-allow-gfe-to-app-a` |

## Network ranges

| Resource | Primary range | Pod secondary | Service secondary |
|---|---|---|---|
| VPC | `risk-vpc` | - | - |
| `risk-usc1` | `10.10.0.0/20` | `risk-usc1-pods` = `10.20.0.0/16` | `risk-usc1-services` = `10.30.0.0/20` |
| `risk-use4` | `10.11.0.0/20` | `risk-use4-pods` = `10.21.0.0/16` | `risk-use4-services` = `10.31.0.0/20` |

Master CIDRs:

- `us-central1`: `172.16.0.0/28`
- `us-east4`: `172.16.0.16/28`

GFE/health-check source ranges:

- `35.191.0.0/16`
- `130.211.0.0/22`

## Regional zones and NEGs

| Region | Zones | Custom NEG name |
|---|---|---|
| `us-central1` | `us-central1-a`, `us-central1-b`, `us-central1-c` | `app-a-neg-usc1` |
| `us-east4` | `us-east4-a`, `us-east4-b`, `us-east4-c` | `app-a-neg-use4` |

Each regional custom NEG name is reused across that region's three zones.
Terraform looks up six zonal `GCE_VM_IP_PORT` NEGs. It must not use a regional
NEG data source.

App A uses three zonal shard Deployments per region. Each shard is pinned to
one frozen zone and has an HPA range of 1-2, for a regional total of 3-6. All
shards keep `app: app-a-gateway`, so one ClusterIP Service and one PDB cover
them. App B remains one Deployment with an HPA range of 2-6.

## Runtime environment

```text
SERVICE_REGION
SERVICE_CLUSTER
SERVICE_VERSION
APP_B_BASE_URL=http://app-b-engine.risk-system.svc.cluster.local:8080
FAULT_CONFIG_PATH=/etc/app-b-faults/faults.json  # App B only
GOOGLE_CLOUD_PROJECT                            # only with Google telemetry
```

Docker Compose may override only the host portion of `APP_B_BASE_URL`; port
`8080` and path `/internal/exchange-rates` remain fixed.

Deployed images must use the full 40-character release commit. A dirty local
review uses `local-<HEAD12>-dirty` so uncommitted source is never presented as
the older commit; deployment scripts continue to reject that local-only value.

## Public App A API

```http
GET /api/exchange-rates
x-correlation-id: optional UUID supplied by client
traceparent: optional W3C trace context
Cache-Control: no-store
```

There is no request body or query input. App A generates missing correlation
and trace identifiers, calls its local App B, and returns App B's response
unchanged.

Response:

```json
{
  "baseCurrency": "USD",
  "rateSnapshots": [
    { "EUR": 0.92, "GBP": 0.78, "JPY": 149.50 },
    { "EUR": 0.93, "GBP": 0.79, "JPY": 150.10 },
    { "EUR": 0.91, "GBP": 0.77, "JPY": 148.90 },
    { "EUR": 0.92, "GBP": 0.79, "JPY": 149.80 },
    { "EUR": 0.93, "GBP": 0.78, "JPY": 149.20 },
    { "EUR": 0.91, "GBP": 0.78, "JPY": 150.00 },
    { "EUR": 0.92, "GBP": 0.77, "JPY": 149.10 },
    { "EUR": 0.93, "GBP": 0.77, "JPY": 149.70 },
    { "EUR": 0.91, "GBP": 0.79, "JPY": 149.40 },
    { "EUR": 0.92, "GBP": 0.78, "JPY": 149.90 }
  ],
  "disclaimer": "Synthetic demonstration rates - not for financial use.",
  "providedBy": {
    "service": "app-b-engine",
    "region": "us-central1",
    "cluster": "gke-risk-usc1",
    "version": "GIT_SHA"
  }
}
```

Status mapping:

- `200`: rates returned
- `400`: unsupported response media request
- `503`: open circuit or unavailable local dependency
- `504`: downstream timeout

App A must not leak App B exception text to callers.

## Internal App B API

```http
GET http://app-b-engine.risk-system.svc.cluster.local:8080/internal/exchange-rates
```

The internal endpoint takes no body or query input and returns the same response
shape as the public API. App A forwards `traceparent` and `x-correlation-id`.
The ten rate snapshots and disclaimer are deterministic; random or external
market values are forbidden. App B returns the complete immutable catalog on
every request, so multiple Pods do not need shared state.

## Browser UI

`GET /` serves a small responsive rate board. It automatically fetches
`GET /api/exchange-rates` with browser caching disabled, shows the first
snapshot, and identifies the serving region and cluster. Each refresh-button
click performs another GET and advances the local display through all ten
snapshots. It sends no selection input; App B remains stateless and every click
still exercises the full dependency path. The page must display the
synthetic-data disclaimer.

## Health APIs

App A:

```text
GET /health/live   process is alive; never calls App B
GET /health/ready  App A is initialized; never depends on App B
GET /health/cell   cached background App B exchange-rate probe state
```

App B:

```text
GET /health/live
GET /health/ready
```

Cell-health constants:

```text
probe interval:       2 seconds
failure threshold:    3 consecutive failures
recovery threshold:   5 consecutive successes
initial state:        UNKNOWN / HTTP 503
```

The probe calls the same no-input internal exchange-rate endpoint with
`x-cell-probe: true`. Both services log it as `dependency_probe`.

## Resilience constants

```text
connect timeout:       500 ms
downstream response:   750 ms
retry:                 at most 1, connectivity/timeout only
circuit breaker:       minimum 5 calls, 50% failure threshold
open duration:         10 seconds
```

## Fault configuration

Path: `/etc/app-b-faults/faults.json`

```json
{
  "injected_latency_ms": 0,
  "injected_error_rate": 0.0
}
```

Use `injected_error_rate: 1.0` for deterministic unavailability. The file is
mounted as a projected directory, never with `subPath`. Fault changes are
cluster-scoped and there is no HTTP fault endpoint.

## Structured log schema

Both services emit valid one-line JSON to stdout from the first application
log. Field types are stable.

```json
{
  "severity": "INFO",
  "message": "exchange rates returned",
  "log_type": "request",
  "service": "app-a-gateway",
  "service_version": "GIT_SHA",
  "region": "us-central1",
  "cluster": "gke-risk-usc1",
  "correlation_id": "550e8400-e29b-41d4-a716-446655440000",
  "trace_id": "32_lowercase_hex_characters",
  "route": "/api/exchange-rates",
  "method": "GET",
  "status_code": 200,
  "latency_ms": 42,
  "downstream_latency_ms": 31,
  "decision": "RATES_RETURNED",
  "error_type": "",
  "stack_trace": "",
  "is_test": false,
  "logging.googleapis.com/trace": "projects/PROJECT_ID/traces/TRACE_ID"
}
```

Allowed `log_type` values:

- `schema_seed`
- `request`
- `dependency_probe`
- `lifecycle`

Rules:

- Cloud Logging severities are top-level values.
- Durations and status codes are numeric.
- Empty optional strings are `""`.
- `trace_id` remains in `jsonPayload` even when the special trace field is set.
- ERROR entries include a parseable Java or .NET `stack_trace`.
- A complete `schema_seed` event is emitted at startup.
- Never log payment data, PII, tokens, headers, credentials, or exception text
  to public callers.

## Workload contract

Per region:

| Workload | Replicas | CPU request/limit | Memory request/limit |
|---|---:|---|---|
| App A (each of three zonal shards) | 1-2 (3-6 total) | `250m` / `500m` | `1Gi` / `1.25Gi` |
| App B | 2-6 | `250m` / `500m` | `512Mi` / `768Mi` |

Each App A shard has an HPA v2 with `min=1`, `max=2`, and a `70%` CPU
target. App B has an HPA v2 with `min=2`, `max=6`, and the same target. App A
uses one shared PDB with `minAvailable: 2`; App B uses `minAvailable: 1`.
Every Deployment uses RollingUpdate with `maxUnavailable: 0`, `maxSurge: 1`,
and a 30-second termination grace period. App A placement is fixed by each
shard's zonal node selector; App B uses soft zonal topology spreading.

## Load-balancer contract

```text
public frontend with domain = HTTPS port 443 only
public HTTP port 80         = absent when TLS is enabled
load_balancing_scheme = EXTERNAL_MANAGED
protocol              = HTTP
balancing_mode        = RATE
max_rate_per_endpoint = 20
capacity_scaler       = 1.0
connection draining   = 30 seconds
backend timeout       = 10 seconds
health path           = /health/cell
health port           = USE_SERVING_PORT
check interval        = 5 seconds
health timeout        = 2 seconds
unhealthy threshold   = 2
healthy threshold     = 3
health logging        = enabled
```

The `protocol = HTTP` value is the private load-balancer-to-Pod backend
protocol. It does not expose a public HTTP listener. A no-domain bootstrap may
temporarily use port 80, but enabling the trusted domain removes that forwarding
rule and its target HTTP proxy rather than redirecting it.

## Terraform state and dependency boundaries

- Terraform: `>= 1.8, < 2.0`
- Google provider: `~> 7.43.0`
- One state key per root stack.
- Apply order:
  `00-bootstrap -> 10-global -> 20-cluster -> Kubernetes Services/NEGs -> 30-lb`.
- `30-lb` is forbidden until both Services report NEG status and all six NEGs
  exist.
- Destroy order:
  `30-lb -> App A Services -> NEG garbage collection -> 20-cluster -> 10-global -> 00-bootstrap -> orphan check`.

## Evidence names

```text
01-budget.png
01-budget.txt
02-clusters.txt
03-negs.txt
04-backend-health-before.txt
05-public-endpoint.json
06-logging.png
06-logging.txt
07-bigquery.png
07-bigquery.txt
07-bigquery-schema.json
07-bigquery-error-rate.csv
07-bigquery-latency-percentiles.csv
07-bigquery-trace-join.csv
07-bigquery-regional-traffic.csv
08-grafana.png
09-failover.csv
09-failover.png
10-backend-health-after.txt
11-error-reporting.png          # optional P1
12-plan-check.txt
13-teardown.txt
```
