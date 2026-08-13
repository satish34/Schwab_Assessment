# Assessment deliverables

## Reviewer start here

| Assignment deliverable | Open |
|---|---|
| Working cluster with an accessible application endpoint | [https://satish.store](https://satish.store) and [`screenshots/05-public-endpoint.png`](screenshots/05-public-endpoint.png) |
| Screenshot or export of the Grafana dashboard | [`grafana-dashboard.png`](grafana-dashboard.png), [`grafana-dashboard.json`](grafana-dashboard.json), and [`how to read the test spikes`](EVIDENCE.md#grafana-dashboard-interpretation) |
| Sample BigQuery queries demonstrating log analysis | [`BIGQUERY.md`](BIGQUERY.md) and [`bigquery/queries`](bigquery/queries) |
| Troubleshooting scenario and resolution | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |
| Infrastructure as Code: Terraform to reproduce the setup | [`SETUP.md`](SETUP.md) and the public repository [`infra`](https://github.com/satish34/Schwab_Assessment/tree/main/infra) |
| Architecture diagram | [`ARCHITECTURE.md`](ARCHITECTURE.md); [`diagrams`](diagrams) contains PNG copies for viewers without Mermaid support |
| Step-by-step setup instructions | [`SETUP.md`](SETUP.md) |
| BigQuery schema and sample queries used in Grafana | [`bigquery/schema.json`](bigquery/schema.json) and [`bigquery/grafana`](bigquery/grafana) |
| Design decisions and rationale | [`DESIGN_DECISIONS.md`](DESIGN_DECISIONS.md) |

This is a candidate-authored GCP/GKE assessment using synthetic currency data.
It is not a Charles Schwab product and does not process customer or market data.

The implementation is in the linked public repository. This package contains
the concise architecture, evidence, reproduction notes, queries, dashboard,
and decisions needed to review it. Read the status boundary below before
interpreting any evidence claim.

## Evidence snapshot

The 2026-08-13 UTC evidence uses App A and App B release
`30fd8e9d60050f4b8cc93f25879883264a8ac30e`. It covers both regional cells,
signed local calls, HTTPS, logs and BigQuery, direct Cloud Trace, Java
Profiler, private GKE-hosted Grafana, bounded platform logs and metrics, team
isolation, and regional recovery. Exact proof and limitations are in
[`EVIDENCE.md`](EVIDENCE.md).

## What the evidence snapshot demonstrates

- Two active regional GKE cells: `us-central1` and `us-east4`.
- Java App A is the only public workload; .NET App B is a cell-local ClusterIP.
- The public edge is HTTPS port 443 only with a managed certificate and six
  zonal App A Pod NEGs.
- App A uses Workload Identity to obtain a Google-signed, audience-bound ID
  token. App B verifies signature, issuer, audience, lifetime, verified email,
  and the exact caller identity before returning rates.
- Restricted Pod Security, non-root/read-only containers, namespace RBAC,
  NetworkPolicy, quotas, separate deployers, and no production Dev principal
  provide a defensible trusted-team boundary.
- App ownership and single-app release lanes are independent. Simultaneous
  compatible changes use the coordinated `deploy-apps` parallel wrapper and
  one final aggregate compatibility gate; direct lane commands are not raced.
- A controlled central-cell fault drained traffic to east and recovered all
  six backends. The measured claim is bounded convergence, not zero downtime.
- Direct sampled tracing proved the App A server -> App A client -> App B
  server parent chain; Java App A produced current CPU and HEAP profiles.
- A private one-hour Grafana Job ran inside GKE with keyless read-only access;
  it was reached through operator loopback and removed after capture.
- Bounded platform coverage proved current control-plane, node, HPA,
  load-balancer, VPC-flow, and firewall logs plus node and edge metrics.

The snapshot endpoint was `https://satish.store`; the API returns ten fixed
synthetic USD-rate snapshots and accepts no body, form, query, login, or
customer input. A fresh accessible-UI capture is
[`screenshots/05-public-endpoint.png`](screenshots/05-public-endpoint.png); the
automated JSON, header, version, and backend gates remain the authoritative
security/behavior proof.

The implementation is in the [public repository](https://github.com/satish34/Schwab_Assessment):
applications under `apps`, Terraform under `infra`, Kustomize under `k8s`,
observability assets under `observability`, and guarded automation under
`scripts`.

## Interview-safe limitations

- Namespace controls are trusted enterprise multi-tenancy, not isolation for
  mutually hostile tenants. Project, clusters, registry, builder, edge, and
  observability are shared because this assessment demonstrates two trusted
  application teams without duplicating the paid platform per team. Regulated
  or mutually untrusted workloads should use separate projects, clusters,
  builders, registries, and administrators.
- The internal App A-to-App B hop is HTTP plus authenticated identity; it is
  not mTLS and does not provide transport confidentiality by itself. A service
  mesh was optional, and adding its certificate, proxy, upgrade, and failure
  surface was not justified for this no-secret synthetic service; production
  financial traffic should add mTLS or equivalent transport protection.
- Cloud Armor and Binary Authorization are implemented behind opt-in flags but
  were disabled because both can add billable usage and Binary Authorization
  changes cluster enforcement. The assignment permits skipping non-free-tier
  features, so the assessment preserves reproducible controls without silently
  accepting cost or rollout risk. No live WAF, rate-limit, attestation, or
  admission-enforcement claim is made.
- The operator retains broad project Owner access, and Terraform uses four
  ignored local state files because this is a short-lived, single-operator
  project without an Organization or shared backend. Production should use
  separated administration, time-bound privilege, and encrypted remote state
  with locking, versioning, audit logs, and recovery tests.
- Recovery was automatic, but health thresholds deliberately debounce
  transient dependency failures instead of draining on one missed probe.
  Faster probes, bounded GET retries, and pre-provisioned survivor capacity
  could reduce transition errors, but require an explicit latency,
  false-drain, capacity, and cost SLO.
- Trace is sampled, Grafana is an ephemeral private evidence session, and
  platform logs are volume-bounded samples. None is presented as a complete
  audit record or durable shared monitoring service.

No assignment PDF, credential, service-account key, token, kubeconfig,
Terraform state, raw log export, or raw failover dataset is included here.
