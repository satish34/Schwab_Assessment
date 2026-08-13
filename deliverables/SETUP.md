# Reproduce in a new GCP project

Run these commands from the repository root in Git Bash. This path targets a
new, separate, preferably empty billing-enabled GCP project. A fresh clone
starts with new Terraform state.

The repository is not a generic organization landing-zone template: its safety
gates deliberately freeze the assessment project, operator, domain, identities,
and resource contracts. A new operator must make and review one coordinated
source commit that ports those values before running any cloud command. Editing
only `.env` is insufficient. An interviewer needs no Google credentials to
review the repository, package, diagrams, dashboard export, or screenshots.

## Prerequisites and manual boundaries

- A billing-enabled GCP project. Terraform adopts it with deletion policy
  `ABANDON`; it does not create the project or attach billing.
- An operator account and dedicated gcloud configuration, with project,
  billing, IAM, GKE, DNS, certificate, quota, and service-account
  impersonation permissions. Port the frozen operator checks to this account.
- An owned domain and access to its registrar. Terraform creates the Cloud DNS
  zone, but the operator must delegate every returned name server at the
  registrar and wait for DNS/certificate propagation.
- Terraform 1.8+, Google Cloud CLI, `gke-gcloud-auth-plugin`, `kubectl`, `jq`,
  `curl`, Docker with Compose, Make, Git Bash, Java 21, .NET 8, and Python 3
  with Matplotlib. PowerShell 7 is used only for the final validated archives.
- A canonical administrator IPv4 `/32`; `0.0.0.0/0` and broad control-plane
  authorization are rejected.

## Prepare the new-project contract before any cloud command

Create a separate, preferably empty, billing-enabled project. Choose the new
project ID, operator email, gcloud configuration, owned domain, billing account,
and administrator `/32`. Search the repository for the frozen assessment
values, update every affected Terraform, script, build, query, dashboard, test,
and documentation contract, then run the local gates and commit the reviewed
port. Do not point a clean clone at an existing populated project.

The new project starts with new local Terraform state in each of the four
roots. `10-global` uses its declarative import to adopt the already-created GCP
project resource. No infrastructure import is expected in a genuinely empty
project. Cloud Quotas retains preference objects, so import only a preference
that already exists before the first `00-bootstrap` plan, using the same
authenticated Terraform variable context as the wrapper:

- `google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity` maps to
  `projects/PROJECT_ID/locations/global/quotaPreferences/compute-cpus-all-regions-96`;
- `google_cloud_quotas_quota_preference.gke_regional_ssd_capacity["us-central1"]`
  maps to
  `projects/PROJECT_ID/locations/global/quotaPreferences/compute-ssd-total-gb-us-central1`;
- `google_cloud_quotas_quota_preference.gke_regional_ssd_capacity["us-east4"]`
  maps to
  `projects/PROJECT_ID/locations/global/quotaPreferences/compute-ssd-total-gb-us-east4`.

A genuinely empty project needs no quota-preference import. Any other populated
project requires complete resource/state adoption and is outside this workflow.

Project/billing creation, registrar delegation, and certificate propagation
remain external to Terraform.

## 1. Configure and prove the source locally

```bash
cp .env.example .env
```

After completing the reviewed cross-file port, set the new project ID, real
billing-account ID, administrator `/32`, gcloud configuration, owned domain,
and both optional security flags in `.env`. Keep the flags at their reviewed
defaults unless cost and behavior are separately approved:

```text
ENABLE_CLOUD_ARMOR=0
ENABLE_BINARY_AUTHORIZATION=0
```

Authenticate interactively, select the exact account/project, then run the
fail-closed local gates:

```bash
gcloud auth login
make preflight
make fmt
make test
make local-up
make local-verify
docker compose --env-file .tmp/local-integration/compose.env down
```

## 2. Apply the four Terraform boundaries in order

For `00-bootstrap` and `10-global`, each plan target saves the exact binary plan
and a 30-minute metadata contract. Review its output, then apply without
changing the project, operator, commit, stack source, variables, or Terraform
context. The apply consumes that same plan and refuses stale or changed input.
These ignored local state and plan files must remain in each stack directory
until the apply and, for state, ordered teardown.

```bash
make bootstrap-plan
TF_AUTO_APPROVE=1 make bootstrap

make global-plan
TF_AUTO_APPROVE=1 make global
```

`00-bootstrap` enables required APIs, creates the $30 budget, and requests a
96-vCPU project quota ceiling. Quota approval is external, reserves no CPU,
guarantees no zonal capacity, and has no direct charge. `10-global` creates the
VPC, subnets, immutable registry, identities, log sinks/datasets, static IP,
DNS zone, and managed-certificate resources.

Delegate all returned Cloud DNS name servers at the registrar:

```bash
terraform -chdir=infra/10-global output -json dns_name_servers
```

Wait for public delegation and the managed certificate to become active. This
manual registrar step cannot be completed by the project Terraform.

Preview the regional Autopilot cells, then run the separate guarded apply:

```bash
make clusters-plan
TF_AUTO_APPROVE=1 make clusters
```

`clusters-plan` is a human preview. `make clusters` regenerates an internal
plan and applies it only if the exact cluster contract accepts it; it does not
consume a general saved plan. The default path rejects replacement; any
one-time replacement requires its separate explicit flag and narrower contract.

The desired zones are central `b/c/f` and east `a/b/c`. A new project creates
them directly; any replacement of an existing cluster is a separate guarded
operation and is not part of this reproduction path.

## 3. Commit, build, and deploy immutable application releases

Cloud Build refuses a dirty tree. After human approval, commit the exact source
and use the resulting full 40-character SHA; do not reuse the evidence SHA for
new source and never publish `latest`.

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
test -z "$(git status --porcelain --untracked-files=all)"

make build
make build-grafana GRAFANA_IMAGE_TAG="$RELEASE_SHA"

make deploy-apps \
  APP_A_IMAGE_TAG="$RELEASE_SHA" \
  APP_B_IMAGE_TAG="$RELEASE_SHA"

make wait-negs \
  APP_A_IMAGE_TAG="$RELEASE_SHA" \
  APP_B_IMAGE_TAG="$RELEASE_SHA"
```

`deploy-apps` applies the Ops-owned Kustomize platform first, then runs the two
app lanes with separate short-lived deployer identities and kubeconfigs. The
NEG gate requires six exact ready App A Pod endpoints before the edge can be
attached.

Review and apply the final load-balancer stack:

```bash
make lb-plan
# Review the saved exact plan, then consume it within 30 minutes:
TF_AUTO_APPROVE=1 make lb \
  APP_A_IMAGE_TAG="$RELEASE_SHA" \
  APP_B_IMAGE_TAG="$RELEASE_SHA"

make verify \
  APP_A_IMAGE_TAG="$RELEASE_SHA" \
  APP_B_IMAGE_TAG="$RELEASE_SHA"
```

After the paired bootstrap, either compatible app can use its independent lane
while supplying the current peer version:

```bash
make deploy-app-a APP_A_IMAGE_TAG="$NEW_A_SHA" APP_B_IMAGE_TAG="$LIVE_B_SHA"
make deploy-app-b APP_A_IMAGE_TAG="$LIVE_A_SHA" APP_B_IMAGE_TAG="$NEW_B_SHA"
```

Run one direct single-app command at a time; each performs the combined
compatibility gate. For two compatible changes released simultaneously, use
the coordinated `make deploy-apps` command instead. It safely defers the two
lane-level combined gates, runs both isolated lanes in parallel, waits for
both, and then runs one aggregate pair gate.

## 4. Generate release-specific evidence

Run these only for the exact approved SHA pair; never relabel screenshots from
an older deployment as evidence for a new release.

```bash
make seed-traffic APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify-bigquery APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify-cloud-observability APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify-platform-observability

make capture-observability-manifest \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-cloud \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-platform

make capture-observability-grafana-start GRAFANA_IMAGE_TAG="$RELEASE_SHA"
# Save evidence/08-grafana.png through the printed 127.0.0.1 URL.
make capture-observability-grafana-verify GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-grafana-cleanup GRAFANA_IMAGE_TAG="$RELEASE_SHA"

make verify-error-reporting
make test-failover APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make plan-check ENABLE_CLOUD_ARMOR=0 ENABLE_BINARY_AUTHORIZATION=0
make secret-scan
```

The dedicated Grafana build bakes the checksum-pinned BigQuery plugin into an
Artifact Registry image and publishes only the explicit release-SHA tag. The
runtime resolves that tag to one digest before rendering its manifest; it does
not download a plugin or image from Docker Hub. The private one-hour Job is
reached only through an operator loopback port-forward. Cleanup removes its Job
and ConfigMaps; there is no public endpoint, Secret, PVC, or standing service.

## State and teardown exception

Each new deployment creates ignored local state in four Terraform roots.
Preserve those state files for drift checks and ordered teardown. Local state
lacks shared locking, centralized recovery, and durable team access; a
production deployment should bootstrap an encrypted, versioned remote backend
before these stacks, then migrate each state under a reviewed change. This
repository intentionally does not pretend that a backend can create itself
with the same state it is meant to hold.

Do not delete local state and do not run teardown during review. After explicit
authorization, use the repository's guarded `make destroy` workflow so the
edge, NEGs, clusters, global resources, and bootstrap resources are removed in
dependency order. No PDF is required or included in this handoff.
