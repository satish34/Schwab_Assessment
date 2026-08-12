# BigQuery checks

These queries are for an explicitly approved production log reader. The
identity needs project-level `roles/bigquery.jobUser` plus dataset-level
`roles/bigquery.dataViewer` on `risk_logs`; the Dev persona has no production
access by default. Run the commands from the repository root in Git Bash, a
Unix-like Bash shell, or Cloud Shell after cloning the repository. Local use
requires the Google Cloud CLI (including `bq`) and `sed`.
`roles/logging.viewer` is needed only for the broader project Logs Explorer UI
path described in
[`docs/BIGQUERY.md`](../../docs/BIGQUERY.md).

Replace `PROJECT_ID` only at execution time. Run these after the `stdout` table
contains real App A and App B rows. Every query prunes the table's `timestamp`
partition to the last six hours.

The `00_trace_*.sql` queries accept a named `trace_id` parameter. Start with
the across-app timeline, or use the App A/App B variants to isolate one side:

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
