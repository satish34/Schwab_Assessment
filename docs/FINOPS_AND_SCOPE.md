# FinOps and scope

## Cost controls

The project has a $30 monthly budget with current-spend alerts at 50%, 80%,
90%, and 100%. Alerts are notifications, not a spending cap. The practical
controls are a dedicated project, small Autopilot requests, bounded test
traffic, narrow log export, partition-pruned BigQuery queries, and ordered
teardown followed by an orphan check.

The implementation plan estimated about $7-$15 for roughly 24 hours. That is a
planning range, not measured billing evidence, and Cloud Billing can lag. The
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

Terraform state is local and gitignored. This kept bootstrap simple for a
single-machine assessment, but loss of this working directory would complicate
safe teardown. A production team should use a restricted, versioned remote
backend and a managed CI identity.

## Security status

Implemented controls include private GKE nodes, an administrator-only control
plane `/32`, GKE Workload Identity Federation, Google-signed App A service
tokens, scoped service accounts, a private App B ClusterIP, ingress
NetworkPolicy, hardened Pod/container security contexts, immutable full-SHA
tags, and no user-managed service-account keys. App B returns `401` for a
missing token and validates the signature and caller claims for authenticated
requests.

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
| Shared VPC and enterprise role separation | The Gmail account has no GCP Organization/folder hierarchy | Move networking and CI/deploy duties into separate projects and identities |
| Remote Terraform state | Local ignored state met the single-operator deadline | Use a versioned remote backend with scoped CI access and recovery testing |
| NAT, proxy-only subnet, and private service access | No arbitrary internet egress, proxy-only load balancer, or managed private service needs them | Add only for a verified dependency and include its cost/failure path |
| Database, cache, queue, and backups | The synthetic currency provider is intentionally stateless and has no persistent volume | Choose services from real durability and consistency requirements; test regional recovery |
| MCI, multi-cluster Gateway, and MCS | Standalone NEGs give direct Terraform edge ownership without Fleet/MCS or cross-cluster calls | Re-evaluate if Kubernetes-native global policy outweighs added controllers and cost |
| Full tracing and Java Profiler | Structured logs, trace joins, Error Reporting, and required dashboard sources took priority | Add least-privilege agents/exporters and verify they remain off the request failure path |
| Durable shared Grafana hosting | The assessment uses a bounded local evidence runtime rather than exposing telemetry publicly | Use Grafana Cloud or a private hosted instance with SSO, a keyless reader identity, and audited Viewer access |

The surviving cell handled the bounded synthetic test. That does not prove
production capacity or an SLO. Before production, pre-provision one-region
peak capacity, test longer failures and deploy rollbacks, and define recovery
and error-budget targets from measured demand.
