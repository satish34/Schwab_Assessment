# BigQuery schema and queries

## Proved application dataset

For release `30fd8e9d60050f4b8cc93f25879883264a8ac30e`, Cloud Logging exported
App A and App B structured stdout into the day-partitioned table
`schwab-assessment-gke.risk_logs.stdout`. The retained `risk_logs` name is a
technical infrastructure identifier; the application uses currency language.

The sanitized live metadata is copied as [`bigquery/schema.json`](bigquery/schema.json).
It records `timestamp` plus these nullable `jsonPayload` fields:

| Field | Type | Use |
|---|---|---|
| `service`, `service_version` | STRING | Component and immutable release |
| `region`, `cluster` | STRING | Serving cell |
| `log_type`, `message`, `decision` | STRING | Event class and outcome |
| `method`, `route`, `status_code` | STRING / FLOAT | HTTP operation and result |
| `latency_ms`, `downstream_latency_ms` | FLOAT | Public and dependency latency |
| `trace_id`, `correlation_id` | STRING | Cross-service join keys |
| `error_type`, `stack_trace` | STRING | Bounded failure detail |
| `is_test` | BOOLEAN | Controlled-evidence marker |

The Cloud Logging envelope also supplies query predicates such as
`resource.labels.namespace_name`, `resource.labels.cluster_name`, `severity`,
and `trace`. The packaged schema is intentionally sanitized and is not a table
export or customer dataset.

## New reader: prerequisites

Production access is explicit; the Dev persona does not receive it by default.
Grant an approved user or, preferably, a `prod-log-readers` Google Group only:

| Need | Least-privilege grant | Scope |
|---|---|---|
| Run queries | `roles/bigquery.jobUser` | Project |
| Read application logs | `roles/bigquery.dataViewer` | `risk_logs` dataset |
| Read sampled platform logs | `roles/bigquery.dataViewer` | Optional `currency_platform_logs` dataset |
| Use the current Logs Explorer | `roles/logging.viewer` | Project; broader than application logs |

Logs Explorer access is separate and is not needed for the BigQuery SQL. Do not
grant Viewer, Editor, Owner, BigQuery Admin, or Private Logs Viewer merely for
application troubleshooting.

An administrator should grant a Google Group rather than individual users:

1. In **IAM & Admin > IAM > Grant access**, grant the group **BigQuery Job
   User** on the project.
2. In **BigQuery > Explorer > risk_logs > Sharing > Permissions**, grant the
   same group **BigQuery Data Viewer** on that dataset.
3. Add or remove people through the group. Grant **Logs Viewer** separately only
   when raw project-wide Logs Explorer access is required.

The current implementation does not create a restricted app-only log view.
BigQuery Job User can incur query cost, and Data Viewer can query and export
rows, so access should be time-bounded and reviewed. The examples below use a
six-hour partition predicate and a 100 MiB maximum-bytes limit.

## Query through the Google Cloud UI

### BigQuery Studio

1. Sign in as the approved reader, select the project, and open **BigQuery**.
2. Expand `risk_logs > stdout` in **Explorer** and open a new SQL query.
3. Paste one of the three `00_trace_*.sql` files below. Replace `PROJECT_ID`
   in the table identifier with the selected project ID.
4. Choose **Edit > Query settings > Query parameters > Add parameter**. Set
   name `trace_id` (without `@`), type `STRING`, and value to the 32-character
   lowercase hexadecimal trace ID. Save.
5. Select **Run**. Start with the across-app query for the ordered App A/App B
   timeline; use either service-specific query to narrow the result.

### Logs Explorer

With the additional `roles/logging.viewer` grant, open **Logging > Logs
Explorer**, select **Last 6 hours**, enable **Show query**, and run:

```text
resource.type="k8s_container"
log_id("stdout")
(resource.labels.namespace_name="currency-app-a" OR
 resource.labels.namespace_name="currency-app-b")
jsonPayload.trace_id="0123456789abcdef0123456789abcdef"
```

Choose oldest-first display in **Preferences > View**. To isolate App A or App
B, replace the parenthesized namespace expression with one exact namespace
predicate. Logs Explorer is best for quick raw-entry inspection; BigQuery is
the repeatable SQL path.

## Included analysis SQL

All SQL is read-only and contains no credential. Replace `PROJECT_ID` only when
the frozen deployment contract has been intentionally ported.

| Query | Question answered |
|---|---|
| [`00_trace_all_apps.sql`](bigquery/queries/00_trace_all_apps.sql) | Given one trace ID, what is the ordered log timeline across App A and App B? |
| [`00_trace_app_a.sql`](bigquery/queries/00_trace_app_a.sql) | Given one trace ID, what did public App A log? |
| [`00_trace_app_b.sql`](bigquery/queries/00_trace_app_b.sql) | Given one trace ID, what did internal App B log? |
| [`01_error_rate.sql`](bigquery/queries/01_error_rate.sql) | How many public App A requests and 5xx responses occurred per minute? |
| [`02_latency_percentiles.sql`](bigquery/queries/02_latency_percentiles.sql) | What were p50, p95, and p99 App A latencies per minute? |
| [`03_trace_join.sql`](bigquery/queries/03_trace_join.sql) | Did App A and App B emit matching trace/correlation IDs in the same cell? |
| [`04_regional_traffic.sql`](bigquery/queries/04_regional_traffic.sql) | Which region and service handled successful requests? |
| [`05_auth_rejections.sql`](bigquery/queries/05_auth_rejections.sql) | Which cell rejected unauthenticated App B calls, and why? |
Run the trace lookup with a named parameter so the supplied value is not
concatenated into SQL:

```bash
PROJECT_ID="schwab-assessment-gke"
TRACE_ID="0123456789abcdef0123456789abcdef"

sed "s/PROJECT_ID/${PROJECT_ID}/g" \
  bigquery/queries/00_trace_all_apps.sql \
  | bq --project_id="$PROJECT_ID" --location=US query \
      --use_legacy_sql=false \
      --maximum_bytes_billed=104857600 \
      --parameter="trace_id:STRING:${TRACE_ID}"
```

Run this command from the unzipped deliverables directory in Git Bash, a
Unix-like Bash shell, or Cloud Shell after uploading or copying the SQL files.
Local use requires the Google Cloud CLI (including `bq`) and `sed`; authenticate
with `gcloud auth login`. In the repository, run from its root and use
`observability/bigquery/00_trace_all_apps.sql` instead. PowerShell cannot run
this syntax unchanged. Change the project ID only for an intentional port.

The two BigQuery Grafana panels use cell-separated, dashboard-time-bounded SQL:

- [`01_error_rate_by_cell.sql`](bigquery/grafana/01_error_rate_by_cell.sql)
- [`02_latency_by_cell.sql`](bigquery/grafana/02_latency_by_cell.sql)

The release gate proved typed application rows, cross-service trace joins,
regional coverage, bounded authentication-rejection analysis, and current
request/latency data for both cells. The populated results are visible in
[`grafana-dashboard.png`](grafana-dashboard.png).

## Bounded platform dataset

The separate Terraform-managed `currency_platform_logs` dataset receives
sampled GKE control-plane/node, HTTPS load-balancer, VPC-flow, firewall, and
health-check logs. It uses partitioned tables, 30-day default partition
expiration, and a dedicated sink writer rather than mixing variable platform
schemas into the stable application table.

The live gate found fresh entries for every configured source. Its capped
BigQuery check read 12 fresh `http_load_balancer` rows from
`currency_platform_logs.requests`, processing 1,716 bytes under a 100 MiB
maximum. Five-percent VPC/load-balancer sampling and ten-percent selected
control-plane/node/firewall sampling bound volume and cost; this dataset is
useful for operational trends, not complete forensic accounting.
