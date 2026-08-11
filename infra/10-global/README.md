# 10-global

This stack creates the shared VPC, regional GKE ranges, Artifact Registry,
global IP, health-check firewall, BigQuery log sink, and scoped node, build,
dashboard, and App A caller service accounts. Only the `app-a-gateway`
Kubernetes service account may impersonate `currency-app-a-caller`, through
`roles/iam.workloadIdentityUser`; the identity receives no project role. It
owns the private Cloud Build source bucket, where source archives expire after
seven days. It also removes the unused default VPC and strips Editor from
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
