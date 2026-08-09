# Grafana dashboard

`risk-dashboard.json` uses BigQuery for App A errors and latency, and Cloud
Monitoring for restarts and utilization. Every query separates the two cells.

The provisioning files are for self-hosted Grafana. Install
`grafana-bigquery-datasource` 3.2.0, mount the dashboard at
`/var/lib/grafana/dashboards`, and run Grafana on GCP with the existing
`grafana-reader` identity through an attached service account or GKE Workload
Identity. The data sources use metadata-based authentication; do not create a
service-account key.

For Grafana Cloud, create data sources with UIDs `risk-bigquery` and
`risk-cloud-monitoring`, then import the dashboard JSON. Use a supported
keyless federation path to the existing restricted `grafana-reader` identity;
do not broaden its IAM or create a key.

Validate version-controlled content without credentials:

```bash
bash scripts/verify-grafana.sh --static
```

The live gate requires `GRAFANA_URL` and a session-only `GRAFANA_TOKEN`. It
checks source data in both cells, both Grafana data-source health endpoints,
the imported dashboard, and every panel query:

```bash
make verify-grafana
```
