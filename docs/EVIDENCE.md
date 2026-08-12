# Evidence index

Verification is tied to project `schwab-assessment-gke`. App A and App B are
both deployed with image SHA
`8af2f2de66d834a73f4339071b492676a667c069`. Raw artifacts are retained locally
and intentionally excluded from the public source tree; this index names them
without publishing their contents.

## Verified requirements

| Requirement | Command or operation | Verified result | Evidence location |
|---|---|---|---|
| Budget and project safety | `make preflight`, `make capture-evidence` | Dedicated billing-enabled project; $30 budget with 50/80/90/100 current-spend alerts | `01-budget.png`, `01-budget.txt` |
| Two regional GKE cells | `make verify APP_A_IMAGE_TAG=8af2f2d... APP_B_IMAGE_TAG=8af2f2d...` | Regional Autopilot clusters in `us-central1` and `us-east4`; at least three ready App A and two ready App B Pods in each | `02-clusters.txt` |
| Immutable release | `make build`, image verifier, and workload verifier | Both full-SHA tags exist, no `latest`; registry and deployed-image checks passed | `02-clusters.txt` |
| Private local App B | Regional workload verifier | Each App A called only its cell-local App B ClusterIP; App B has no external address or load-balancer NEG | `02-clusters.txt` |
| Signed local service call | Regional workload verifier and safe direct probe | App A obtains a Google-signed ID token through GKE Workload Identity Federation; authenticated calls pass in both cells and unauthenticated App B calls return `401` | `02-clusters.txt`, `14-service-auth.txt` |
| Team and deployment isolation | `make verify`, namespace isolation gate | Separate App A/App B namespaces and deployers passed own-versus-peer RBAC checks; policy, Secret, exec, and peer-namespace access were denied; no Dev production RBAC exists | `17-team-isolation.txt` |
| Six Pod NEGs | `make wait-negs APP_A_IMAGE_TAG=8af2f2d... APP_B_IMAGE_TAG=8af2f2d...` | One real App A Pod IP on port 8080 in central zones `b/c/f` and east zones `a/b/c` | `03-negs.txt` |
| Global edge | `make verify APP_A_IMAGE_TAG=8af2f2d... APP_B_IMAGE_TAG=8af2f2d...` | `https://satish.store` uses an ACTIVE managed certificate, has 3/3 healthy endpoints per region, and has no HTTP forwarding rule, proxy, or redirect | `04-backend-health-before.txt`, `05-public-endpoint.json` |
| Structured logs | Traffic generation and logging capture | Schema tests cover the frozen JSON contract; selected live App A/App B entries have matching trace and correlation fields | `06-logging.png`, `06-logging.txt` |
| BigQuery analysis | `make verify-bigquery APP_A_IMAGE_TAG=8af2f2d... APP_B_IMAGE_TAG=8af2f2d...` | The partitioned table returned 21 error-rate rows, 21 latency rows, 100 trace joins, 57 regional-traffic rows, 14 authentication-rejection rows, and no current export errors | `07-bigquery-schema.json`, `07-bigquery.png`, `07-bigquery.txt`, and [`SQL`](../observability/bigquery/README.md) |
| Grafana dashboard | `bash scripts/local-grafana-evidence.sh start` | Both keyless data sources were healthy; all four live panels returned real data and the rendered dashboard was visually inspected | `08-grafana.png` |
| Error Reporting | `make verify-error-reporting`, Google Cloud Console one-hour view | Controlled failures were grouped: 190 App B injected-fault occurrences and 43 App A dependency-failure occurrences | `11-error-reporting.png` |
| Regional failover | `make test-failover APP_A_IMAGE_TAG=8af2f2d... APP_B_IMAGE_TAG=8af2f2d...` | `us-central1` drained; `us-east4` survived; public traffic converged in 63.167 seconds; both cells and all six backends recovered | `09-failover.csv`, `09-failover.png`, `10-backend-health-after.txt` |

The failover run sent 171 requests at 0.973 requests/second. Eighteen failed,
all during the transition; none failed outside that window. Cached cell health
drained in 40.454 seconds, load-balancer health drained in 55.449 seconds, and
public traffic converged in 63.167 seconds, 7.718 seconds after backend drain.
Cache and load-balancer recovery took 62.181 and 86.420 seconds. Backend health
was 1/1 in every zone before and after; the three faulted-region zones were 0/1
during the fault.

The saved queries returned 21 error-rate rows, 21 latency rows, 100 App A/App B
trace joins, 57 regional-traffic rows, and 14 authentication-rejection rows.

## Disabled or deferred controls

| Item | Status | What remains |
|---|---|---|
| Deployed-release drift report | **PASS for `8af2f2d...`** | `make plan-check` reported `NO_CHANGES` for all four stacks and wrote `12-plan-check.txt`. Any later source release requires a new drift report. |
| Cloud Armor | **IMPLEMENTED / DISABLED LIVE** | The default flag is `0`; no policy is attached and no feature charge is active. Enabling it requires separate cost approval and a bounded rate/WAF exercise. Local proof: `15-cloud-armor.txt`. |
| Binary Authorization | **IMPLEMENTED / DISABLED LIVE** | The default flag is `0`; both clusters report admission enforcement disabled. Enabling it requires separate cost approval, an in-place-only plan, and a non-persisting denial test. Local proof: `16-binary-authorization.txt`. |
| Teardown and orphan check | **NOT RUN** | Run only after authorization with the exact destroy confirmation. A successful ordered teardown writes `13-teardown.txt`. |
| Cloud Trace and Java Profiler | **IMPLEMENTED / NOT IN BASELINE EVIDENCE** | Tests cover the direct keyless exporters, 10% App A sampling boundary, three-span parent chain, and request-safe failure behavior. A matching immutable deployment must pass the live verifier before these controls are claimed live. |
| Expanded platform observability | **PARTIAL LIVE / NEW EVIDENCE REQUIRED** | A 2026-08-12 read-only check found both clusters healthy with the intended logging components. The repository also defines a platform dataset/sink, VPC flow logging, backend request logging, an observability namespace, and a private GKE Grafana Job; each needs matching runtime proof. |

## Evidence for a new release

Evidence is immutable-release-specific. Do not reuse or relabel the retained
`8af2f2d...` artifacts for a newer image. After deploying a new full SHA, run
the API, authentication, workload, NEG, Trace, Profiler, platform, Grafana,
failover, and drift gates, then capture the new artifacts:

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
make capture-evidence \
  APP_A_IMAGE_TAG="$RELEASE_SHA" \
  APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-manifest \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-cloud \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-platform
make capture-observability-grafana-start GRAFANA_IMAGE_TAG="$RELEASE_SHA"
# Save evidence/08-grafana.png from the printed loopback URL.
make capture-observability-grafana-verify GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-grafana-cleanup GRAFANA_IMAGE_TAG="$RELEASE_SHA"
```

The phased commands write `18-release-manifest.txt` through
`21-gke-grafana.txt` only after each live gate passes. They never store access
tokens or Profiler payload bytes. The CLI capture is separate from the direct
Grafana screenshot. Do not treat a
missing file, generated placeholder, or static dashboard check as equivalent
to the completed live panel gate.
