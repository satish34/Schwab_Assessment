# BigQuery schema and queries

The application sink exports only the two application namespaces to the
day-partitioned table `schwab-assessment-gke.risk_logs.stdout`. The dataset name
is a retained infrastructure identifier; the application and documentation use
currency terminology. A separate bounded `currency_platform_logs` sink is
defined for sampled platform logs and is not queried by these application
reports.

## New reader: access and prerequisites

Production access is denied unless IAM grants it explicitly. Application
developers do not receive production-log access through the Dev persona. Use a
separate approved user or, preferably, a `prod-log-readers` Google Group.

| Need | Least-privilege grant | Scope |
|---|---|---|
| Run BigQuery queries | `roles/bigquery.jobUser` | Project |
| Read application log rows | `roles/bigquery.dataViewer` | `risk_logs` dataset only |
| Read sampled platform rows, after that dataset exists | `roles/bigquery.dataViewer` | Optional `currency_platform_logs` dataset only |
| Use the current Logs Explorer | `roles/logging.viewer` | Project; broader than application logs |

`roles/logging.viewer` is not required for the BigQuery queries. Do not grant
basic Viewer, Editor, Owner, BigQuery Admin, or Private Logs Viewer merely to
investigate application logs. The machine reader follows the same split: it
can create BigQuery query jobs and read the application dataset, but it cannot
administer either resource and has no service-account key.

An administrator grants access once:

1. Prefer a Google Group such as `prod-log-readers@company.example`; use a
   direct user only when group management is unavailable.
2. In **IAM & Admin > IAM > Grant access**, grant the group **BigQuery Job
   User** on the project.
3. In **BigQuery > Explorer > risk_logs > Sharing > Permissions**, grant the
   same group **BigQuery Data Viewer** on that dataset.
4. Grant **Logs Viewer** separately only when raw Logs Explorer access is
   required. This repository does not create an app-only log view; implementing
   one would require a dedicated log view and `roles/logging.viewAccessor`.

BigQuery Job User can create billable query jobs, and Data Viewer can query and
export dataset rows. The examples therefore restrict time and set a query-byte
limit; access should be time-bounded and reviewed according to company policy.

## Look up one trace in the Google Cloud UI

### BigQuery Studio

1. Sign in with the approved reader identity, select the intended project, and
   open **BigQuery**.
2. In **Explorer**, expand the project, `risk_logs`, and `stdout` to confirm the
   dataset is visible. Open a new SQL query.
3. Copy one of the `00_trace_*.sql` files listed below into the editor. Replace
   only `PROJECT_ID` in the table identifier with the selected project ID.
4. In the query editor toolbar, choose **Edit > Query settings**. Under
   **Query parameters**, add a parameter named `trace_id` (without `@`), type
   `STRING`, with the 32-character lowercase hexadecimal trace ID as its value.
   Save the settings.
5. Select **Run**. The query returns an oldest-to-newest timeline for the last
   six hours. Use the across-app query first, then the App A or App B variant
   when one side needs isolation.

BigQuery parameters are used for values, not table identifiers; this is why the
project token is replaced separately. Keeping the six-hour timestamp predicate
also bounds the partition scan.

### Logs Explorer

This path requires the separate `roles/logging.viewer` grant:

1. Select the project and open **Logging > Logs Explorer**.
2. Set the time range to **Last 6 hours**, enable **Show query** if necessary,
   and paste the following filter after replacing the trace ID:

   ```text
   resource.type="k8s_container"
   log_id("stdout")
   (resource.labels.namespace_name="currency-app-a" OR
    resource.labels.namespace_name="currency-app-b")
   jsonPayload.trace_id="0123456789abcdef0123456789abcdef"
   ```

3. Select **Run query**, choose oldest-first display in **Preferences > View**,
   and expand the matching entries. To isolate one application, replace the
   parenthesized namespace expression with one exact namespace predicate.

Logs Explorer reads the Cloud Logging buckets directly. BigQuery Studio reads
the routed, partitioned `risk_logs.stdout` table; use BigQuery for repeatable
SQL analysis and Logs Explorer for quick raw-entry inspection.

## Query-facing schema

The exported Cloud Logging envelope provides these fields used by the checked-in
queries:

| Path | Type | Use |
|---|---|---|
| `timestamp` | TIMESTAMP | Partition pruning and time-series grouping |
| `resource.type` | STRING | Confirms `k8s_container` rows |
| `resource.labels.project_id` | STRING | Source project |
| `resource.labels.cluster_name` | STRING | GKE cluster identity |
| `resource.labels.location` | STRING | GKE region |
| `resource.labels.namespace_name` | STRING | Restricts analysis to `currency-app-a` and `currency-app-b` |
| `resource.labels.pod_name` | STRING | Pod-level troubleshooting |
| `resource.labels.container_name` | STRING | App A/App B container selection |
| `severity` | STRING | Logging severity |
| `trace`, `spanId` | STRING | Cloud Logging trace correlation |

The application-owned `jsonPayload` contract is:

| Field | Type | Purpose |
|---|---|---|
| `service`, `service_version` | STRING | Component and immutable image release |
| `region`, `cluster` | STRING | Serving cell |
| `log_type`, `message`, `decision` | STRING | Event category and outcome |
| `method`, `route` | STRING | HTTP operation |
| `status_code` | FLOAT | HTTP result |
| `latency_ms`, `downstream_latency_ms` | FLOAT | End-to-end and App B latency |
| `trace_id`, `correlation_id` | STRING | Cross-service join keys |
| `error_type`, `stack_trace` | STRING | Bounded failure details |
| `is_test` | BOOLEAN | Controlled-evidence marker |

All fields are nullable because Cloud Logging evolves the BigQuery schema as
new structured fields arrive. Terraform owns the sink and partitioned dataset
in [`infra/10-global`](../infra/10-global). The application dataset currently
has no default partition expiration; the six-hour query bounds control scans,
not stored-data retention.

## Sample analysis queries

The exact parameterized SQL is checked in under
[`observability/bigquery`](../observability/bigquery):

- [`00_trace_all_apps.sql`](../observability/bigquery/00_trace_all_apps.sql) — ordered App A and App B logs for one trace ID
- [`00_trace_app_a.sql`](../observability/bigquery/00_trace_app_a.sql) — App A logs only for one trace ID
- [`00_trace_app_b.sql`](../observability/bigquery/00_trace_app_b.sql) — App B logs only for one trace ID
- [`01_error_rate.sql`](../observability/bigquery/01_error_rate.sql)
- [`02_latency_percentiles.sql`](../observability/bigquery/02_latency_percentiles.sql)
- [`03_trace_join.sql`](../observability/bigquery/03_trace_join.sql)
- [`04_regional_traffic.sql`](../observability/bigquery/04_regional_traffic.sql)
- [`05_auth_rejections.sql`](../observability/bigquery/05_auth_rejections.sql)
The trace queries are the first incident-troubleshooting path. Supply a known
`trace_id` as a named BigQuery parameter to return an ordered log timeline
without constructing SQL from untrusted input:

```bash
PROJECT_ID="schwab-assessment-gke"
TRACE_ID="0123456789abcdef0123456789abcdef"

sed "s/PROJECT_ID/${PROJECT_ID}/g" \
  observability/bigquery/00_trace_all_apps.sql \
  | bq --project_id="$PROJECT_ID" --location=US query \
      --use_legacy_sql=false \
      --maximum_bytes_billed=104857600 \
      --parameter="trace_id:STRING:${TRACE_ID}"
```

Run this Bash command from the repository root in Git Bash, or from Google
Cloud Shell after cloning the repository and changing into its root. Before a
local run, install the Google Cloud CLI (including `bq`) and `sed`, then
authenticate the approved identity with `gcloud auth login`. Git Bash,
macOS/Linux Bash, WSL, and Cloud Shell can run the syntax; PowerShell cannot run
it unchanged. Change the frozen project ID only for an intentional project port.

The first two Grafana panels use the namespace-scoped queries in
[`observability/grafana/queries`](../observability/grafana/queries). The complete
four-panel dashboard export is
[`currency-dashboard.json`](../observability/grafana/currency-dashboard.json).
