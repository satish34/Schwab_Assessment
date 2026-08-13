# Grafana dashboard

`currency-dashboard.json` contains exactly the four assignment panels:

1. BigQuery application error rates over time.
2. Pod restart counts grouped and labeled by Kubernetes namespace.
3. Request latency percentiles (p50, p95, and p99) from BigQuery.
4. CPU and memory resource-utilization trends from Cloud Monitoring.

Cell and service labels remain on the series for troubleshooting context.
`risk_logs` remains because it is the existing BigQuery dataset identifier.
Cloud Monitoring queries include both `currency-app-a` and `currency-app-b`
namespaces.

The provisioning files are for self-hosted Grafana. Install
`grafana-bigquery-datasource` 3.3.1, mount the dashboard at
`/var/lib/grafana/dashboards`, and run Grafana on GCP with the existing
`grafana-reader` identity through an attached service account or GKE Workload
Identity. The data sources use metadata-based authentication; do not create a
service-account key.

For Grafana Cloud, create data sources with UIDs `currency-bigquery` and
`currency-cloud-monitoring`, then import the dashboard JSON. Use a supported
keyless federation path to the existing restricted `grafana-reader` identity;
do not broaden its IAM or create a key.

From the repository root, validate version-controlled content without
credentials:

```bash
bash scripts/verify-grafana.sh --static
```

For local source review, this bounded loopback helper remains available:

```bash
bash scripts/local-grafana-evidence.sh start
```

Open the printed URL, then run `verify` or `cleanup` as needed. The runtime
impersonates the restricted `grafana-reader` for at most one hour, exposes the
token only through an internal metadata-compatible Docker network, and enables
anonymous Viewer access only on `127.0.0.1`. It never creates a service-account
key.

```bash
bash scripts/local-grafana-evidence.sh verify
bash scripts/local-grafana-evidence.sh cleanup
```

For an existing HTTPS Grafana instance, `make verify-grafana` still accepts a
session-only `GRAFANA_TOKEN`. Both paths check source data, both data-source
health endpoints, the imported dashboard, and every panel query:

```bash
make verify-grafana
```

The GKE evidence path bakes the checksum-pinned official BigQuery plugin 3.3.1
archive into a scanned Artifact Registry image. Build it from a clean commit
using an explicit full SHA:

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
make build-grafana GRAFANA_IMAGE_TAG="$RELEASE_SHA"
```

The build still fails closed on every fixed `HIGH` or `CRITICAL` finding. Four
findings in upstream compiled Grafana/plugin code have exact binary-path,
reason, and 2026-08-20 expiry entries in `trivyignore.yaml`. The scan prints
those suppressed findings; any fifth finding or expired exception blocks
publication. The complete exception file is checksum-frozen in both the local
submission gate and Cloud Build, so paths or ID mappings cannot be broadened
silently. The exceptions cover unused Tempo/S3/xDS and a read-only plugin
filesystem path, not a general severity waiver.

The one-hour Job in `currency-observability` resolves that tag to one immutable
digest before rendering the manifest. It performs no runtime plugin or Docker
Hub download and has no Service, Ingress, Secret, or persistent volume. A
dedicated keyless KSA/GSA reads the data, and the operator reaches it only
through a loopback port-forward:

```bash
make gke-grafana GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make gke-grafana-status GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make cleanup-gke-grafana GRAFANA_IMAGE_TAG="$RELEASE_SHA"
```

For final release evidence, use the phased wrappers instead:

```bash
make capture-observability-grafana-start GRAFANA_IMAGE_TAG="$RELEASE_SHA"
# Save evidence/08-grafana.png from the printed loopback URL.
make capture-observability-grafana-verify GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-grafana-cleanup GRAFANA_IMAGE_TAG="$RELEASE_SHA"
```

The verifier text is saved only after a complete pass; the screenshot remains
an explicit operator step.

Treat this path as live only after the GKE runtime gate and screenshot are
captured for the same immutable SHA.
