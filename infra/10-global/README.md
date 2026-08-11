# 10-global

This stack creates the shared network, registry, global IP, log export, and
service accounts. Its access model is deliberately small:

| Persona | Identity and exact Google IAM | Kubernetes scope |
|---|---|---|
| Dev | No production principal; changes flow through repository review and lower environments | No production-like project or cluster access |
| Ops | `satish.cse7@gmail.com`: existing `roles/owner`, managed outside this stack | Platform administration; this broad single-operator access is an assessment limitation |
| SRE | `grafana-reader`: dataset `roles/bigquery.dataViewer`; project `roles/bigquery.jobUser`, `roles/monitoring.viewer`, and custom `grafanaProjectReader` | No Kubernetes access; read-only dashboard data |
| CI/CD | Shared `risk-cloud-build`: `roles/artifactregistry.writer` on the repository, `roles/logging.logWriter` on the project, and `roles/storage.objectViewer` on the source bucket. Per-app deployers: `roles/container.clusterViewer` | Each deployer can change only its own Deployments, HPAs, and PDBs |

`satish.cse7@gmail.com` receives `roles/iam.serviceAccountTokenCreator` on the
SRE and deployer service accounts, so those identities use short-lived
impersonation; Terraform creates no keys. `roles/container.clusterViewer` can
read project-level cluster metadata, while Kubernetes RBAC is the namespace
authorization boundary.

Only `currency-app-a/app-a-gateway` may impersonate
`currency-app-a-caller`, through `roles/iam.workloadIdentityUser`; this runtime
identity has no project role. Both apps still share the build identity and
Artifact Registry repository, so deployment isolation—not build
isolation—is claimed. That shared supply-chain boundary is a remaining
cross-team blast radius; production would split the builders and repositories.

The private Cloud Build source bucket expires source archives after seven
days. This stack also removes the unused default VPC and strips Editor from
default service accounts.

When `ENABLE_BINARY_AUTHORIZATION=1`, it owns the project policy:
Google-managed system images and only the exact `risk/app-a` and `risk/app-b`
repository paths are allowed; the default rule denies everything else. This is
path allowlisting, not signed build attestation. GKE documents fail-open
behavior during service or quota failure. The live/default flag is `0`, so no
project policy is created.

The existing project is imported with `auto_create_network = false`. Because
the provider only removes the default VPC while creating a project, a one-time
Terraform migration checks its signature, firewall rules, account, project,
and VM use before removing it. A customized or in-use network is rejected.
The project deletion policy is `ABANDON`, so this stack cannot delete it.
Destroying the stack does remove the exported-log dataset after evidence is
saved.

Run this after `00-bootstrap` through the root `make global` command. The apply
gate must confirm the sink's returned writer identity has
`roles/bigquery.dataEditor` on only `risk_logs`.

An empty `domain_name` is only a temporary bootstrap or recovery mode. The
final assessment supplies an owned domain, so apply `00-bootstrap` first to
enable the DNS and Certificate Manager APIs, then delegate the domain to the
output name servers. Terraform creates no certificate key.
