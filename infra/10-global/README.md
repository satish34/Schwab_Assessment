# 10-global

This stack creates the shared VPC, regional GKE ranges, Artifact Registry,
global IP, health-check firewall, BigQuery log sink, and scoped node, build,
and dashboard service accounts. It owns the private Cloud Build source bucket,
where source archives expire after seven days. It also removes the unused
default VPC and strips Editor from default service accounts.

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

`domain_name` is empty for the core HTTP path. If an owned domain is supplied,
apply `00-bootstrap` first so it enables the DNS and Certificate Manager APIs,
then delegate it to the output name servers. Terraform creates no certificate
key.
