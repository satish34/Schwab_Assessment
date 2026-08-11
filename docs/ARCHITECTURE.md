# Architecture

## Why standalone zonal NEGs

The implementation uses one Terraform-managed global external Application
Load Balancer and six standalone zonal GKE Pod NEGs instead of Multi Cluster
Ingress or multi-cluster Gateway. This keeps the complete load-balancer graph
in Terraform, avoids Fleet/Multi-cluster Services setup, and preserves the
chosen Kubernetes NetworkPolicy model.

Terraform does not create or populate the NEGs. Kubernetes declares the named
App A Service exposure, and GKE creates and synchronizes the zonal NEGs.
Terraform validates and attaches those six existing groups. This is
infrastructure as code across two control planes, not a claim that Terraform
owns every object.

There is no Kubernetes Ingress, Gateway, or multi-cluster ingress controller in
the request path. The Terraform load balancer addresses the GKE-managed Pod
NEGs directly; that control-plane difference from the assignment example is
intentional and disclosed in `PLAN_VS_ASSIGNMENT.md`.

The tradeoff is more orchestration and a strict apply order. Regional Autopilot
placement first left some zones without a real endpoint, so App A now has one
zonal shard Deployment in each frozen zone. Each shard scales from one to two
Pods, giving three to six App A Pods per region and one real endpoint in each
NEG. This is deterministic, but it costs two extra minimum App A Pods and uses
three small HPAs per region.

## Request and health flow

```mermaid
flowchart TB
  Client["Browser or API client"] --> ALB["HTTPS satish.store:443<br/>Global external ALB"]
  Armor["Cloud Armor<br/>optional; disabled live"] -.->|attaches when enabled| ALB
  Identity["GKE Workload Identity<br/>currency-app-a-caller"]

  subgraph USC1["us-central1 - gke-risk-usc1"]
    A1["App A - Java<br/>currency UI and API"] -->|Google-signed ID token| B1["App B - .NET<br/>private rate provider"]
  end

  subgraph USE4["us-east4 - gke-risk-use4"]
    A2["App A - Java<br/>currency UI and API"] -->|Google-signed ID token| B2["App B - .NET<br/>private rate provider"]
  end

  ALB --> A1
  ALB --> A2
  Identity -.->|mints audience-bound token| A1
  Identity -.->|mints audience-bound token| A2
  A1 --> Logs["Cloud Logging"]
  B1 --> Logs
  A2 --> Logs
  B2 --> Logs
  Logs --> BQ["BigQuery risk_logs"]
  Logs --> Errors["Error Reporting"]
  BQ --> Grafana["Grafana application panels"]
  Monitoring["Cloud Monitoring"] --> Grafana
```

The remaining `risk-*` names are frozen infrastructure identifiers created
before the application became a currency demo. The public content and APIs use
currency language; replacing healthy clusters, registry paths, and data names
only for cosmetic renaming would add migration risk and cost.

```text
client
  -> GET / or GET /api/exchange-rates on https://satish.store:443
  -> EXTERNAL_MANAGED load balancer
  -> one of six healthy App A Pod NEG endpoints
  -> Java App A in that regional cell
  -> local app-b-engine ClusterIP
  -> GET /internal/exchange-rates on .NET App B in the same regional cell
```

App B has no public endpoint, Ingress, load-balancer NEG, or cross-cluster
route. The two cells share the global frontend and versioned desired state, but
not an application dependency path or datastore.

Both cells are active-active: while healthy, either region can receive a new
request. There is no strict primary. The load balancer uses `/health/cell`,
which returns App A's cached view of a background exchange-rate probe to local
App B. It never calls App B synchronously.

Kubernetes uses `/health/ready`, which does not depend on App B. A local App B
failure therefore leaves App A Pods ready while `/health/cell` turns unhealthy
after three failed probes. The load balancer drains that cell. Recovery waits
for five successful probes before the cell becomes eligible again; this slower
path limits flapping.

The measured test faulted `us-central1`. Cached health drained in 45.388
seconds, load-balancer health drained in 61.134 seconds, and public traffic
converged on `us-east4` in 67.804 seconds. Cache and load-balancer recovery took
49.413 and 73.459 seconds, and all six backends returned healthy. Fifteen of 162
requests failed during transition; none failed before the fault or after
public convergence. The design does not claim zero downtime.

## Isolation and ownership

Namespace ingress is denied by default. App A accepts port 8080 only from the
documented Google frontend and health-check ranges. App B accepts port 8080
only from App A Pods in `risk-system`. Both containers run non-root with a
read-only root filesystem, dropped capabilities, no privilege escalation, and
RuntimeDefault seccomp.

The live release binds only the `app-a-gateway` Kubernetes service account to
the dedicated `currency-app-a-caller` IAM service account. App A requests an
audience-bound, Google-signed ID token from the GKE metadata server and sends
it to App B. App B validates the signature, issuer, audience, expiry, verified
email, and exact caller identity. App B receives no Google identity or project
role. A direct unauthenticated request returns `401`; authenticated calls pass
in both cells.

Cloud Armor and Binary Authorization are implemented as opt-in Terraform
controls. Both flags are `0` in the live environment: no Cloud Armor policy is
attached, and neither cluster enforces Binary Authorization. This avoids their
feature charges while keeping the reviewed implementation available for a
separately approved rollout.

Default-deny egress is deliberately not enabled. Adding it without tested DNS,
metadata, identity, registry, and telemetry allowances creates a larger outage
risk than it removes in this short assessment. A production rollout should add
and verify those paths before enforcing egress denial.

Ownership is split by dependency boundary:

- `00-bootstrap`: APIs and the $30 budget.
- `10-global`: VPC, ranges, registry, global IP, log sink, BigQuery, IAM, and
  the optional Binary Authorization policy.
- `20-cluster`: two regional Autopilot clusters and the optional admission
  enforcement mode.
- Kubernetes/Kustomize: workloads, Services, health, scaling, policies, and
  fault profiles; GKE owns NEG lifecycle.
- `30-lb`: health check, backend service, optional Cloud Armor attachment, six
  NEG attachments, proxies, URL maps, and forwarding rules.

The stacks currently use ignored local Terraform state. That was acceptable
for a single-machine assessment, but it is not a team-safe production backend.

## Failure boundaries

A failed App B Pod stays inside its local ClusterIP. Failure of the whole local
rate-provider path drains App A for that cell; the other cell has its own cluster,
App B replicas, and NEGs. A failed App A endpoint is removed independently.
Logging, BigQuery, Monitoring, and Grafana are outside the request path.

The surviving region was sized for the bounded assessment load. HPA is not
instant failover capacity; production capacity must be pre-provisioned and
tested against peak regional traffic.

The public origin is HTTPS-only at `satish.store`. Cloud DNS and Certificate
Manager automate validation and renewal without putting a private key in
Terraform state. There is no public port 80 rule or redirect. Internal
load-balancer health checks and App A-to-App B calls remain HTTP inside the
private service path.
