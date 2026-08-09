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
- Cell failover: App A's background evaluation probe controls cached
  `/health/cell` state. Kubernetes readiness never depends on App B.
- Observability: Cloud Logging to partitioned BigQuery for application panels;
  Cloud Monitoring for restart and utilization panels.

## Resource names

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
RISK_REGION
RISK_CLUSTER
SERVICE_VERSION
APP_B_BASE_URL=http://app-b-engine.risk-system.svc.cluster.local:8080
FAULT_CONFIG_PATH=/etc/risk-faults/faults.json   # App B only
GOOGLE_CLOUD_PROJECT                            # only with Google telemetry
```

Docker Compose may override only the host portion of `APP_B_BASE_URL`; port
`8080` and path `/v1/evaluate` remain fixed.

## Public App A API

```http
POST /v1/risk
Content-Type: application/json
x-correlation-id: optional UUID supplied by client
traceparent: optional W3C trace context
```

Request:

```json
{
  "requestId": "550e8400-e29b-41d4-a716-446655440000",
  "amount": 1250.50,
  "currency": "USD",
  "merchantCategory": "ELECTRONICS",
  "countryCode": "US",
  "channel": "CARD_NOT_PRESENT"
}
```

Response:

```json
{
  "requestId": "550e8400-e29b-41d4-a716-446655440000",
  "score": 48,
  "decision": "REVIEW",
  "rulesFired": ["CARD_NOT_PRESENT", "AMOUNT_OVER_1000"],
  "evaluatedBy": {
    "service": "app-b-engine",
    "region": "us-central1",
    "cluster": "gke-risk-usc1",
    "version": "GIT_SHA"
  }
}
```

Status mapping:

- `200`: evaluated decision
- `400`: request validation failure
- `503`: open circuit or unavailable local dependency
- `504`: downstream timeout

App A must not leak App B exception text to callers.

## Internal App B API

```http
POST http://app-b-engine.risk-system.svc.cluster.local:8080/v1/evaluate
```

The request and response payloads are the public contract. App A forwards
`traceparent` and `x-correlation-id`.

Decision values are exactly:

```text
APPROVE | REVIEW | DECLINE
```

Evaluation is deterministic for a given request. Random production decisions
are forbidden.

## Health APIs

App A:

```text
GET /health/live   process is alive; never calls App B
GET /health/ready  App A is initialized; never depends on App B
GET /health/cell   cached background App B evaluation-probe state
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

The probe uses a fixed synthetic evaluation request and
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

Path: `/etc/risk-faults/faults.json`

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
  "message": "risk evaluation completed",
  "log_type": "request",
  "service": "app-a-gateway",
  "service_version": "GIT_SHA",
  "region": "us-central1",
  "cluster": "gke-risk-usc1",
  "correlation_id": "550e8400-e29b-41d4-a716-446655440000",
  "trace_id": "32_lowercase_hex_characters",
  "route": "/v1/risk",
  "method": "POST",
  "status_code": 200,
  "latency_ms": 42,
  "downstream_latency_ms": 31,
  "decision": "REVIEW",
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
02-clusters.txt
03-negs.txt
04-backend-health-before.txt
05-public-endpoint.json
06-logging.png
07-bigquery.png
08-grafana.png
09-failover.csv
09-failover.png
10-backend-health-after.txt
11-error-reporting.png          # optional P1
12-plan-check.txt
13-teardown.txt
```
