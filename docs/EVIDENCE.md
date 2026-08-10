# Evidence index

Evidence is tied to project `schwab-assessment-gke` and deployed image SHA
`4151c68e57968ea4b56acc56e8b5f443f7617970`. That SHA is not the current
repository HEAD; later infrastructure, verification, and documentation commits
do not change the running images.

These artifacts currently prove the pre-refactor release. The no-input currency
rate release must receive a new immutable SHA and a complete evidence refresh
before this index can describe it as live.

## Verified requirements

| Requirement | Command or operation | Verified result | Evidence location |
|---|---|---|---|
| Budget and project safety | `make preflight`, `make capture-evidence` | Dedicated billing-enabled project; $30 budget with 50/80/90/100 current-spend alerts | [Summary](../evidence/01-budget.png), [CLI](../evidence/01-budget.txt) |
| Two regional GKE cells | `make verify IMAGE_TAG=4151c68e...` | Regional Autopilot clusters in `us-central1` and `us-east4`; three ready App A and two ready App B Pods in each at minimum scale | [Clusters and workloads](../evidence/02-clusters.txt) |
| Immutable release | `make build`, image verifier, and workload verifier | Both full-SHA tags exist, no `latest`; registry and deployed-image checks passed | [Deployed image fields](../evidence/02-clusters.txt) |
| Private local App B | Regional workload verifier | Each App A called only its cell-local App B ClusterIP; App B has no external address or load-balancer NEG | [Workload evidence](../evidence/02-clusters.txt) |
| Six Pod NEGs | `make wait-negs IMAGE_TAG=4151c68e...` | One real App A Pod IP on port 8080 in every frozen zone | [NEG evidence](../evidence/03-negs.txt) |
| Global edge | `make verify IMAGE_TAG=4151c68e...` | Three healthy endpoints per region; canonical public request returned HTTP 200 and a real App B region | [Backend health](../evidence/04-backend-health-before.txt), [public response](../evidence/05-public-endpoint.json) |
| Structured logs | Traffic generation and logging capture | Schema tests cover the frozen JSON contract; selected live App A/App B entries have matching trace and correlation fields | [Screenshot](../evidence/06-logging.png), [log excerpt](../evidence/06-logging.txt) |
| BigQuery analysis | `make verify-bigquery IMAGE_TAG=4151c68e...` | The verifier checked partitioning and field types; `risk_logs.stdout` has both regions/services, all decisions, controlled errors, latency, 100 trace joins, and no current export errors | [Expected log schema](../CONTRACTS.md#structured-log-schema), [summary](../evidence/07-bigquery.png), [query results](../evidence/07-bigquery.txt), [SQL](../observability/bigquery/README.md) |
| Grafana dashboard | `bash scripts/local-grafana-evidence.sh start` | Both keyless data sources were healthy; all four live panels returned real data and the rendered dashboard was visually inspected | [Dashboard](../evidence/08-grafana.png) |
| Error Reporting | `make verify-error-reporting`, Google Cloud Console seven-day view | Five real groups exist; controlled App B and App A exceptions are grouped as application errors | [Error groups](../evidence/11-error-reporting.png) |
| Regional failover | `make test-failover IMAGE_TAG=4151c68e...` | `us-central1` drained; `us-east4` survived; both cells and all six backends recovered | [Traffic CSV](../evidence/09-failover.csv), [timeline](../evidence/09-failover.png), [recovery](../evidence/10-backend-health-after.txt) |

The failover run sent 167 requests at 0.973 requests/second. Sixteen failed,
all during the drain window. Cached cell health drained in 47.961 seconds and
the edge in 62.935 seconds. Cache and edge recovery took 59.471 and 73.792
seconds. Backend health was 1/1 in each of six zones before and after; the three
faulted-region zones were 0/1 during the fault.

The original BigQuery gate sent 318 bounded requests over 442 seconds. Its four
queries returned 18 error-rate buckets, 18 latency buckets, 100 App A/App B
trace joins, and 93 regional traffic groups. The later saved capture includes
additional verification and failover traffic, so `07-bigquery.txt` records
44, 44, 100, and 187 rows respectively.

## Open or deferred evidence

| Item | Status | What remains |
|---|---|---|
| Final drift report | **PASS** | `make plan-check` reported `NO_CHANGES` for all four Terraform stacks and wrote [the drift report](../evidence/12-plan-check.txt). |
| Teardown and orphan check | **NOT RUN** | Run only after authorization with the exact destroy confirmation. A successful ordered teardown writes `13-teardown.txt`. |
| HTTPS | **READY / NOT YET CAPTURED** | `satish.store` resolves to the reserved global IP and its managed certificate is active. The saved release evidence remains HTTP until the approved currency image and HTTPS frontend are deployed and reverified. |
| Profiler and exported Trace | **P1 / NOT CLAIMED** | Cross-service trace IDs exist and join in BigQuery, but Cloud Trace currently has zero exported spans and no Profiler evidence was captured. |

To regenerate safe CLI proof for items 01 through 07, run:

```bash
make capture-evidence IMAGE_TAG=4151c68e57968ea4b56acc56e8b5f443f7617970
```

The CLI capture is separate from the direct Grafana screenshot. Do not treat a
missing file, generated placeholder, or static dashboard check as equivalent
to the completed live panel gate.
