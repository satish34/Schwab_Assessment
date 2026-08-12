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
  `app-b-engine.currency-app-b.svc.cluster.local` ClusterIP.
- Cell failover: App A's background exchange-rate probe controls cached
  `/health/cell` state. Kubernetes readiness never depends on App B.
- Observability: Cloud Logging to partitioned BigQuery for application panels;
  Cloud Monitoring for restart and utilization panels; direct sampled trace
  export; Java App A profiling; and a separate bounded platform-log dataset.
  Every deployed release must prove its own active subset with fresh evidence.
- Optional edge security: Cloud Armor rate limiting and preview-only OWASP
  SQLi/XSS rules are created only when `ENABLE_CLOUD_ARMOR=1`; live value `0`.
- Optional supply chain: Binary Authorization enforcement is created only when
  `ENABLE_BINARY_AUTHORIZATION=1`; live value `0`.

## Resource names

The live foundation was created before the application changed from a risk
example to a currency-rate demo. Existing `risk-*` cloud, network, dataset, and
registry identifiers remain stable technical names. The application namespaces
use current currency names because they can move without replacing the shared
GCP foundation.

| Contract | Value |
|---|---|
| App A namespace | `currency-app-a` |
| App B namespace | `currency-app-b` |
| Regions | `us-central1`, `us-east4` |
| Cluster names | `gke-risk-usc1`, `gke-risk-use4` |
| Kubernetes Services | `app-a-gateway`, `app-b-engine` |
| Container port | `8080` for both applications |
| NEG names | `app-a-neg-usc1`, `app-a-neg-use4` |
| Artifact Registry | `us-central1-docker.pkg.dev/PROJECT_ID/risk` |
| BigQuery dataset | `risk_logs` in `US` |
| Expected BigQuery log table | `stdout`, verified after first export |
| Platform log dataset | `currency_platform_logs` in `US` |
| Backend service | `risk-app-a-gateway-backend` |
| Global address | `risk-global-ip` |
| Cluster node service accounts | `risk-gke-usc1-nodes`, `risk-gke-use4-nodes` |
| App A caller service account | `currency-app-a-caller` |
| App B telemetry service account | `currency-app-b-telemetry` |
| Grafana reader service account | `grafana-reader` |
| App A deployer identity | `currency-app-a-deployer` |
| App B deployer identity | `currency-app-b-deployer` |
| Developer production identity | none; Dev access stops at repository review and lower environments |
| Optional TLS objects | `risk-dns-auth`, `risk-cert`, `risk-cert-map` |
| Health firewall | `risk-allow-gfe-to-app-a` |
| Cloud Armor policy | `currency-edge-waf` |

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
| `us-central1` | `us-central1-b`, `us-central1-c`, `us-central1-f` | `app-a-neg-usc1` |
| `us-east4` | `us-east4-a`, `us-east4-b`, `us-east4-c` | `app-a-neg-use4` |

Each regional custom NEG name is reused across that region's three zones.
Terraform looks up six zonal `GCE_VM_IP_PORT` NEGs. It must not use a regional
NEG data source.

The project-wide `CPUS_ALL_REGIONS` quota preference is frozen at 96 vCPUs.
Terraform manages preference ID `compute-cpus-all-regions-96`, and the
post-bootstrap gate requires Google to have granted at least 96. This value is
a ceiling, not reserved capacity or a spending target.

App A uses three zonal shard Deployments per region. Each shard is pinned to
one frozen zone and has an HPA range of 1-2, for a regional total of 3-6. All
shards keep `app: app-a-gateway`, so one ClusterIP Service and one PDB cover
them. App B remains one Deployment with an HPA range of 2-6.

## Runtime environment

```text
SERVICE_REGION
SERVICE_CLUSTER
SERVICE_VERSION
APP_B_BASE_URL=http://app-b-engine.currency-app-b.svc.cluster.local:8080
APP_B_AUTH_MODE=google-id-token
APP_B_TOKEN_AUDIENCE=https://app-b-engine.schwab-assessment.internal
APP_A_IDENTITY_EMAIL=currency-app-a-caller@PROJECT_ID.iam.gserviceaccount.com  # App B only
FAULT_CONFIG_PATH=/etc/app-b-faults/faults.json  # App B only
GOOGLE_CLOUD_PROJECT=PROJECT_ID                 # deployed apps
OTEL_TRACING_ENABLED=true                       # App A
OTEL_TRACES_SAMPLER_ARG=0.1                     # App A
CLOUD_PROFILER_ENABLED=true                     # App A
OTEL_TRACES_EXPORTER=otlp                       # App B
OTEL_EXPORTER_OTLP_ENDPOINT=https://telemetry.googleapis.com/v1/traces  # App B
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf       # App B
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
unchanged. The response repeats `x-correlation-id` and `traceparent` and also
returns `x-trace-id`, the exact 32-character trace identifier written to both
services' structured request logs.

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
GET http://app-b-engine.currency-app-b.svc.cluster.local:8080/internal/exchange-rates
```

The internal endpoint takes no body or query input and returns the same response
shape as the public API. App A forwards `traceparent` and `x-correlation-id`.
The ten rate snapshots and disclaimer are deterministic; random or external
market values are forbidden. App B returns the complete immutable catalog on
every request, so multiple Pods do not need shared state.

The deployed internal request also requires:

```http
Authorization: Bearer GOOGLE_SIGNED_ID_TOKEN
```

The `currency-app-a/app-a-gateway` Kubernetes service account is linked through
Workload Identity Federation to the dedicated `currency-app-a-caller` IAM
service account.
App A requests a one-hour Google-signed ID token from the GKE metadata server
for the exact audience `https://app-b-engine.schwab-assessment.internal`,
caches it, and refreshes it before expiry. App B verifies Google's signature,
issuer, audience, lifetime, verified email claim, and exact App A IAM service
account email before serving the request. A missing, duplicate, malformed,
expired, wrong-audience, or wrong-caller token returns internal HTTP `401`.
App A treats token acquisition failure or an internal `401` as unavailable
App B and preserves the public `503` contract.

Tokens and authorization headers are never logged. Health endpoints remain
unauthenticated. Docker Compose must set `APP_B_AUTH_MODE=disabled` explicitly
because the local machine has no GKE metadata identity. It must also use the
dedicated `.NET` `LocalCompose` environment and Spring `local-compose` profile;
the standard `.NET` environments and normal Spring runtime profiles reject
disabled authentication. Deployed manifests and verification require
`google-id-token` and fail closed.

The internal hop remains HTTP. The signed token authenticates App A but does
not encrypt traffic or prevent replay of a captured token before expiry;
ClusterIP isolation and ingress NetworkPolicy reduce exposure. Production
would add mTLS for confidentiality and stronger replay resistance.

The App A identity receives only
`roles/telemetry.tracesWriter`, `roles/serviceusage.serviceUsageConsumer`, and
`roles/cloudprofiler.agent`. App B uses its own
`currency-app-b-telemetry` identity with the first two trace-export roles.
Both mappings are exact KSA-to-GSA Workload Identity bindings; no key is stored.
App A makes a 10% sampling decision for root and remote-parent requests and
does not trust a caller-supplied sampled flag. App B continues that W3C
decision. Public App A server, App A client, and private App B server spans
must form one three-span parent chain. Probes and rejected authentication
requests do not export spans. Export is asynchronous and request-safe.

## Browser UI

`GET /` serves a small responsive rate board. It automatically fetches
`GET /api/exchange-rates` with browser caching disabled, shows the first
snapshot, and shows only the serving GCP region and request trace ID.
It does not display service, cluster, or image-version metadata. Each
refresh-button click performs another GET and advances the local display
through all ten snapshots. It sends no selection input; App B remains stateless
and every click still exercises the full dependency path. The page must display
the synthetic-data disclaimer.

App A sets `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and a
hash-based Content Security Policy without `unsafe-inline` on every response.
Trusted HTTPS responses also set
`Strict-Transport-Security: max-age=31536000; includeSubDomains`; local HTTP
must not set HSTS.

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
scoped to App B in one regional cell and there is no HTTP fault endpoint.

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
- App B authentication rejection uses status `401`, decision `AUTH_REJECTED`,
  and a non-secret error type; the token and header value are never logged.

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

## Team and deployment isolation

App A runs in `currency-app-a`; App B runs in `currency-app-b`. A
platform-owned Kustomize layer owns both namespaces, restricted Pod Security
labels, Services and NEG annotations, Kubernetes service accounts, cell
configuration, the fault ConfigMap, NetworkPolicies, quotas, Roles, and
RoleBindings. Each app deployment lane owns only its Deployments, HPAs, and
PDBs.

`currency-app-a-deployer` and `currency-app-b-deployer` have only
`roles/container.clusterViewer` in Google IAM and write access through a Role
in their own namespace. They cannot change Services, service accounts,
NetworkPolicies, quotas, RBAC, Secrets, Pod exec/attach, or the other app.
Developers have no production-like GCP or Kubernetes identity; changes enter
through repository review, testing, and lower environments. The two deployers
use short-lived impersonation; no key is created.

The two app pipelines use separate kubeconfig and work directories. Each direct
lane runs independently with a pair compatibility gate. For simultaneous
backward-compatible changes, the coordinated deploy script defers lane gates,
runs both lanes concurrently, then executes one aggregate gate; two arbitrary
direct invocations are not supported. Breaking API changes require an
expand-contract release. The clusters, project, VPC, edge, build identity,
Artifact Registry repository, and observability stack remain shared platform
boundaries. This is trusted enterprise multi-tenancy, not hostile-tenant
isolation.

The platform layer defines `currency-observability` with restricted
Pod Security, default-deny ingress, no app-team RBAC, and a quota of one Pod and
one Job. The quota fixes requests at 250m CPU, 512Mi memory, and 256Mi ephemeral
storage, with limits of 500m, 768Mi, and 640Mi; data/tmp `emptyDir` volumes are
capped at 512Mi/128Mi. Services, Secrets, and persistent volume claims are
forbidden. Its `currency-grafana` KSA maps keylessly to the read-only
`grafana-reader` GSA.
The Grafana build requires an explicit full-SHA `GRAFANA_IMAGE_TAG`, bakes the
checksum-pinned BigQuery plugin into its scanned Artifact Registry image, and
publishes no `latest` tag. The GKE launcher resolves that tag to one digest and
renders a digest-only manifest; the Job downloads neither a plugin nor a Docker
Hub image at runtime.

Rollout success does not mean zero-downtime regional failover. The failover
gate permits failures only inside the measured convergence window and requires
zero failures after convergence plus complete backend recovery. Capped retries
for idempotent GETs with exponential backoff and jitter, faster health tuning,
and pre-provisioned survivor capacity could reduce transition errors; that SLO
tuning is out of scope.

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
backend request logs  = pending sample rate 0.05; 1.0 when ENABLE_CLOUD_ARMOR=1
```

The `protocol = HTTP` value is the private load-balancer-to-Pod backend
protocol. It does not configure a public HTTP frontend. A no-domain bootstrap may
temporarily use port 80, but enabling the trusted domain removes that forwarding
rule and its target HTTP proxy rather than redirecting it.

The live backend predates the pending request-log setting. The `0.05` normal
sample and `1.0` Armor sample take effect only after the reviewed `30-lb`
in-place apply.

When `ENABLE_CLOUD_ARMOR=1`, Cloud Armor uses these frozen rules. The default
and current live value is `0`, so no policy is attached and no denial is
claimed.

```text
priority 1000 = OWASP CRS 4.22 SQLi, deny(403), preview=true, sensitivity=1
priority 1010 = OWASP CRS 4.22 XSS,  deny(403), preview=true, sensitivity=1
priority 2000 = per-IP rate_based_ban, allow 120/60s, deny excess with 429
ban threshold = 600/60s; ban duration = 60s
default        = allow
```

The higher rate threshold leaves headroom for the one-request-per-second
failover gate. The evidence exercise sends a bounded burst above 120 but below
600, proving a logged `429` without intentionally banning the operator.

## Binary Authorization contract

When `ENABLE_BINARY_AUTHORIZATION=1`, both Autopilot clusters use
`PROJECT_SINGLETON_POLICY_ENFORCE`. The project policy enables Google's
maintained system-image policy, exempts only the exact Artifact Registry image
paths `risk/app-a`, `risk/app-b`, and `risk/grafana-evidence`, and enforces
`ALWAYS_DENY` for everything else. One guarded live Pod create request for
`docker.io/library/nginx:1.27.5`
must be denied and must not persist a Pod. The default and current live value
is `0`, so cluster enforcement and the denial exercise are disabled.

This is repository allowlisting, not signed build attestation: anyone who can
push to those three protected repository paths could deploy an image. Artifact
Registry writer access therefore remains limited to the build service account.
GKE evaluates this policy on future Pod create/update requests; it does not
evict existing Pods and is documented to fail open during service or quota
failure. `ALWAYS_DENY` describes normal policy evaluation, not an availability
hard-fail guarantee.

## Terraform state and dependency boundaries

- Terraform: `>= 1.8, < 2.0`
- Google provider: `~> 7.43.0`
- One state key per root stack.
- Apply order:
  `00-bootstrap -> 10-global -> 20-cluster -> Kubernetes Services/NEGs -> 30-lb`.
- `30-lb` is forbidden until both Services report NEG status and all six NEGs
  exist.
- `00-bootstrap`, `10-global`, and `30-lb` plans write one ignored exact binary
  plus metadata bound for 30 minutes to project, operator, commit, stack source,
  Terraform context, and plan hash. Their applies consume that same plan and
  reject missing, stale, changed, delete, or replacement scope.
- `20-cluster` is different: its plan target is a human preview; apply creates a
  fresh internal plan and accepts only the narrower cluster contract.
- The existing live project requires the retained four local states. A clean
  clone may target only a separately reviewed project/contract port; any
  populated project requires complete state adoption, and a retained quota
  preference must be imported before the `00-bootstrap` plan.
- Guarded cloud/Terraform entry points reject alternate access-token,
  credential-file, ADC, and impersonation overrides before using the exact
  configured operator identity.
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
07-bigquery-auth-rejections.csv
08-grafana.png
09-failover.csv
09-failover.png
10-backend-health-after.txt
11-error-reporting.png
12-plan-check.txt
13-teardown.txt                 # post-teardown; intentionally absent while live
14-service-auth.txt
15-cloud-armor.txt
16-binary-authorization.txt
17-team-isolation.txt
18-release-manifest.txt
19-cloud-observability.txt
20-platform-observability.txt
21-gke-grafana.txt
```

`18` binds both image versions and the public endpoint to one deployed release
SHA, records the clean documentation HEAD separately, and requires that the
release is that HEAD or its ancestor. Regenerate it after a documentation-only
commit without relabeling the deployed release.
`19` is sanitized
Cloud Trace/Profiler CLI proof, including the exact three-span parent chain and
profile metadata only. `20` proves the bounded platform configuration, fresh
Logging/Monitoring signals, and at least one fresh partition-pruned BigQuery
sink row under a 100 MiB query cap. `21` proves the private GKE Grafana runtime,
signed pinned plugin, healthy keyless data sources, and real data in all four
panels. The browser-captured `08-grafana.png` remains a separate manual visual
step because shell automation must not silently substitute a rendered image for
human review.

Generate `18`–`21` only after the corresponding immutable release is live. Each text
artifact is written through an ignored temporary file and replaces retained
evidence only after its gate passes and a token-pattern scan succeeds. Start
Grafana, capture `08-grafana.png` from its loopback-only URL, verify it, and
always run cleanup; neither the Job nor its port-forward is standing evidence.
