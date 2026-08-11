# Evidence index

Verification is tied to project `schwab-assessment-gke` and deployed image SHA
`cb1cba2fdc0ff997378d5ab86b6121a4f33dfa89`. Raw artifacts are retained
locally and intentionally excluded from the public source tree; this index
names them without publishing their contents.

## Verified requirements

| Requirement | Command or operation | Verified result | Evidence location |
|---|---|---|---|
| Budget and project safety | `make preflight`, `make capture-evidence` | Dedicated billing-enabled project; $30 budget with 50/80/90/100 current-spend alerts | `01-budget.png`, `01-budget.txt` |
| Two regional GKE cells | `make verify IMAGE_TAG=cb1cba2f...` | Regional Autopilot clusters in `us-central1` and `us-east4`; at least three ready App A and two ready App B Pods in each | `02-clusters.txt` |
| Immutable release | `make build`, image verifier, and workload verifier | Both full-SHA tags exist, no `latest`; registry and deployed-image checks passed | `02-clusters.txt` |
| Private local App B | Regional workload verifier | Each App A called only its cell-local App B ClusterIP; App B has no external address or load-balancer NEG | `02-clusters.txt` |
| Signed local service call | Regional workload verifier and safe direct probe | App A obtains a Google-signed ID token through GKE Workload Identity Federation; authenticated calls pass in both cells and unauthenticated App B calls return `401` | `02-clusters.txt`, `14-service-auth.txt` |
| Six Pod NEGs | `make wait-negs IMAGE_TAG=cb1cba2f...` | One real App A Pod IP on port 8080 in every frozen zone | `03-negs.txt` |
| Global edge | `make verify IMAGE_TAG=cb1cba2f...` | `https://satish.store` uses an ACTIVE managed certificate, has 3/3 healthy endpoints per region, and has no HTTP forwarding rule, proxy, or redirect | `04-backend-health-before.txt`, `05-public-endpoint.json` |
| Structured logs | Traffic generation and logging capture | Schema tests cover the frozen JSON contract; selected live App A/App B entries have matching trace and correlation fields | `06-logging.png`, `06-logging.txt` |
| BigQuery analysis | `make verify-bigquery IMAGE_TAG=cb1cba2f...` | The partitioned table has both regions/services, currency results, controlled errors, authentication denials, latency, 100 trace joins, and no current export errors | `07-bigquery-schema.json`, `07-bigquery.png`, `07-bigquery.txt`, and [`SQL`](../observability/bigquery/README.md) |
| Grafana dashboard | `bash scripts/local-grafana-evidence.sh start` | Both keyless data sources were healthy; all four live panels returned real data and the rendered dashboard was visually inspected | `08-grafana.png` |
| Error Reporting | `make verify-error-reporting`, Google Cloud Console one-hour view | Controlled failures were grouped: 183 App B injected-fault occurrences and 58 App A dependency-failure occurrences | `11-error-reporting.png` |
| Regional failover | `make test-failover IMAGE_TAG=cb1cba2f...` | `us-central1` drained; `us-east4` survived; public traffic converged in 67.804 seconds; both cells and all six backends recovered | `09-failover.csv`, `09-failover.png`, `10-backend-health-after.txt` |

The failover run sent 162 requests at 0.974 requests/second. Fifteen failed,
all during the transition; none failed before the fault or after public
convergence. Cached cell health drained in 45.388 seconds, load-balancer health
drained in 61.134 seconds, and public traffic converged in 67.804 seconds.
Cache and load-balancer recovery took 49.413 and 73.459 seconds. Backend health
was 1/1 in every zone before and after; the three faulted-region zones were 0/1
during the fault.

The saved queries returned 17 error-rate rows, 17 latency rows, 100 App A/App B
trace joins, 42 regional traffic rows, and 6 authentication-rejection rows.

## Disabled or deferred controls

| Item | Status | What remains |
|---|---|---|
| Final drift report | **PASS** | `make plan-check` reported `NO_CHANGES` for all four Terraform stacks and wrote `12-plan-check.txt`. |
| Cloud Armor | **IMPLEMENTED / DISABLED LIVE** | The default flag is `0`; no policy is attached and no feature charge is active. Enabling it requires separate cost approval and a bounded rate/WAF exercise. Local proof: `15-cloud-armor.txt`. |
| Binary Authorization | **IMPLEMENTED / DISABLED LIVE** | The default flag is `0`; both clusters report admission enforcement disabled. Enabling it requires separate cost approval, an in-place-only plan, and a non-persisting denial test. Local proof: `16-binary-authorization.txt`. |
| Teardown and orphan check | **NOT RUN** | Run only after authorization with the exact destroy confirmation. A successful ordered teardown writes `13-teardown.txt`. |
| Profiler and exported Trace | **P1 / NOT CLAIMED** | Cross-service trace IDs exist and join in BigQuery, but Cloud Trace currently has zero exported spans and no Profiler evidence was captured. |

Regenerate the safe pre-teardown CLI proof for the deployed release with:

```bash
make capture-evidence IMAGE_TAG=cb1cba2fdc0ff997378d5ab86b6121a4f33dfa89
```

The CLI capture is separate from the direct Grafana screenshot. Do not treat a
missing file, generated placeholder, or static dashboard check as equivalent
to the completed live panel gate.
