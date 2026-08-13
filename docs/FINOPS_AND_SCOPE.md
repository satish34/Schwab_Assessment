# FinOps and scope

## Cost controls

The project has a $30 monthly budget with current-spend alerts at 50%, 80%,
90%, and 100%. Alerts are notifications, not a spending cap. The practical
controls are a dedicated project, small Autopilot requests, bounded test
traffic, narrow log export, partition-pruned BigQuery queries, and ordered
teardown followed by an orphan check.

Terraform manages a 96-vCPU project-wide `CPUS_ALL_REGIONS` ceiling and a
900-GB `SSD_TOTAL_GB` ceiling in each deployment region. Quota changes have no
direct fee and allocate nothing; actual Autopilot resources remain billable.
The constrained east cell used five 100-GB node disks in steady state. Nine
hundred GB provides one temporary 100-GB surge slot for each of the four
Deployments reconciled in parallel during a zero-unavailable release at the
current minimum replica counts. Namespace ResourceQuotas
bound each app team, while the standing project Owner remains the broad
exception. Google approval and zonal capacity are external dependencies.

An initial estimate was about $7-$15 for roughly 24 hours. That is not measured
billing evidence, and Cloud Billing can lag. The
live topology also has one more minimum App A Pod per region than the original
estimate because every zonal NEG needed a real endpoint. No final actual cost
is claimed here.

The environment remains live for review and is still billable. Teardown has
not been authorized or executed. The project itself is retained by design.

Cloud Armor and Binary Authorization are implemented behind Terraform feature
flags, but both flags are `0` in the live environment. No Cloud Armor policy is
attached and neither cluster enforces Binary Authorization, so no feature
charge is active. Current pricing must be reviewed before either control is
enabled; that opt-in also requires a fresh plan and explicit cost approval.

The observability configuration is deliberately bounded: Cloud Trace uses
10% App A sampling; Profiler has no ingestion charge; normal backend logs and
VPC flows use 5% samples; control-plane and firewall export uses 10%; the
platform dataset retains partitions for 30 days; and the GKE Grafana Job is
limited to one Pod for at most one hour. Trace includes the first 2.5 million
spans per billing account each month before paid ingestion; Logging and
BigQuery free tiers may cover this small test, but usage above them is billable.
Pricing and free-tier eligibility can change, so verify current GCP prices
before apply. No cost claim is made without matching runtime usage evidence.

Terraform state is local and gitignored. This keeps a single-operator bootstrap
small, but losing state complicates drift management and teardown. A new empty
project starts new state after the reviewed cross-file contract port; any
pre-existing declared resource requires import. A production team should use a
restricted, versioned remote backend and a managed CI identity.

## Security status

Implemented controls include private GKE nodes, an administrator-only control
plane `/32`, GKE Workload Identity Federation, Google-signed App A service
tokens, separate application namespaces, namespace-scoped deployer and
RBAC, quotas, no developer production principal, a private App B ClusterIP,
ingress NetworkPolicy, hardened Pod/container security contexts, immutable
full-SHA tags, guarded cloud entry points that reject alternate
credential/impersonation overrides, and no user-managed service-account keys.
App B returns `401` for a missing token and
validates the signature and caller claims for authenticated requests.

The image gate blocks every fixable HIGH or CRITICAL vulnerability. App A had
no HIGH or CRITICAL findings. App B's Microsoft Debian runtime base still
reported 17 HIGH and 5 CRITICAL OS advisories with no vendor fix; its .NET
packages had none. The build uses Trivy `--ignore-unfixed`, so this is a known
base-image risk, not a claim of a clean scan. Production handling would track
an owner and expiry, rebuild as soon as a fixed base is published, and rerun
the scan before promotion.

## Deliberate production gaps

| Gap | Why it is out of this assessment | Production direction |
|---|---|---|
| DNSSEC on the new delegation | It was disabled for the registrar nameserver switch; publishing unmatched keys would break resolution | Enable Cloud DNS DNSSEC, then publish its exact DS record at Squarespace and verify before enforcing it |
| Live WAF and rate limiting | The Cloud Armor implementation is disabled to avoid a feature charge for the short review window | Recheck pricing, enable with approval, review preview matches, then enforce only tuned rules |
| Default-deny egress | Untested DNS, metadata, identity, and telemetry exceptions can break Autopilot workloads | Inventory destinations, allow only verified paths, then enforce and retest |
| Service mesh and mTLS | App A-to-App B stays inside one cell and the feature was optional | Add only with an identity, certificate rotation, and operational ownership model |
| Binary Authorization enforcement and signed attestations | The opt-in allowlist is disabled live and, even when enabled, does not prove who built an allowed image | Enable only after an in-place plan and cost approval; then add attestations tied to the trusted build identity |
| Hard tenant isolation | Both trusted app teams share clusters, project, VPC, build identity, registry, owner access, and observability | Use separate projects/clusters and per-team build repositories for mutually untrusted or regulated workloads |
| Full enterprise role separation | The Gmail account has no GCP Organization/folder hierarchy; Ops is still the project Owner | Bind Dev, Ops, SRE, and CI/CD groups through Cloud Identity and remove standing Owner access |
| Remote Terraform state | Local ignored state met the single-operator deadline | Use a versioned remote backend with scoped CI access and recovery testing |
| NAT, proxy-only subnet, and private service access | No arbitrary internet egress, proxy-only load balancer, or managed private service needs them | Add only for a verified dependency and include its cost/failure path |
| Database, cache, queue, and backups | The synthetic currency provider is intentionally stateless and has no database, persistent volume, or application state in etcd. Terraform, Kustomize, source, and immutable images are the rebuild inputs; no separate GKE etcd or Artifact Registry backup/replication policy is configured | Choose services from real durability and consistency requirements; add cross-region replication, registry retention/replication, remote Terraform state, and tested restore procedures |
| MCI, multi-cluster Gateway, and MCS | Standalone NEGs give direct Terraform edge ownership without Fleet/MCS or cross-cluster calls | Re-evaluate if Kubernetes-native global policy outweighs added controllers and cost |
| .NET continuous profiling | Live Trace covers both apps and current CPU/heap profiles cover Java App A, but this design does not claim an equivalent supported .NET Profiler agent | Evaluate a supported .NET profiler or vendor-neutral alternative, then apply the same keyless identity, bounded collection, and metadata-only evidence rules |
| Durable shared Grafana hosting | The GKE runtime is a one-hour private evidence Job, not a standing service | Use Grafana Cloud or a private hosted instance with SSO, a keyless reader identity, and audited Viewer access |

The surviving cell handled the bounded synthetic test. That does not prove
production capacity, zero downtime, or an SLO. Before production,
pre-provision one-region peak capacity, test longer failures and independent
rollbacks, and define recovery and error-budget targets from measured demand.
Capped retries for idempotent GETs with exponential backoff and jitter, plus
faster health convergence, can reduce transition errors but cannot guarantee
that every in-flight request survives.
