# Reproduce the assessment

This runbook rebuilds the checked-in design in a new, separate, preferably
empty billing-enabled GCP project. A fresh clone starts with new Terraform
state. An interviewer can review the source and run local tests without Google
access.

## External prerequisites

Terraform does not create the Google Cloud account, billing account, project,
or domain registration. Before starting:

- create a new dedicated project and attach an active billing account;
- choose the operator account, dedicated gcloud configuration, project ID,
  owned domain, and administrator `/32` for the new deployment;
- obtain one trusted public administrator IPv4 `/32` for the GKE control
  planes;
- retain control of a domain if trusted HTTPS is required; and
- install Terraform 1.8+, gcloud, kubectl, Docker/Compose, Git Bash, Make, jq,
  Java 21, .NET 8, Python 3, Matplotlib, and PowerShell 7 for final archive
  packaging.

The scripts are deliberately locked to the assessment project, operator,
domain, identities, and related contracts. Before any cloud command, make one
reviewed source commit that ports every affected Terraform, script, build,
query, dashboard, test, and documentation value. Editing only `.env` is not a
portable deployment path.

## Prepare the new-project contract before any cloud command

Start with a separate, preferably empty, billing-enabled project and complete
the reviewed cross-file port described above. The four Terraform roots create
new local state for that deployment. `10-global` includes a declarative import
that adopts `google_project.current`. If the quota preference already exists,
import `google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity` into
`00-bootstrap` before its first plan because the API/provider retains it. Any
other populated project requires complete resource/state adoption and is not
part of this clean-project workflow.

For that exception, use the same authenticated Terraform variable context as
the wrapper and import address
`google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity` with ID
`projects/PROJECT_ID/locations/global/quotaPreferences/compute-cpus-all-regions-96`
before `make bootstrap-plan`.

Billing/project creation remains outside Terraform. DNS registrar
delegation and certificate propagation also remain manual. This runbook does
not claim automatic adoption of a populated project.

## 1. Configure and test locally

Use Git Bash. For source-only review, a clean clone is sufficient. For cloud
work, use the state path chosen above. Copy `.env.example` to ignored `.env`,
then set the new project, billing, operator configuration, domain, and
administrator CIDR using only values from the reviewed contract-port commit.
Keep both paid-control flags at `0` unless a separate cost/change review has
approved them.

```bash
make preflight
make fmt
make test
make local-up
make local-verify
docker compose --env-file .tmp/local-integration/compose.env down
```

No cloud image is built from uncommitted source. Commit only approved changes,
then confirm `git status --porcelain` is empty before continuing.

## 2. Apply Terraform in dependency order

For `00-bootstrap` and `10-global`, the plan target saves the exact binary plan
and a 30-minute metadata contract. Review that output, then apply without
changing the project, operator, commit, stack source, variables, or Terraform
context; the apply consumes that same plan and refuses stale or changed input.

```bash
set -a
source .env
set +a

make bootstrap-plan
TF_AUTO_APPROVE=1 make bootstrap

make global-plan
TF_AUTO_APPROVE=1 make global

make clusters-plan
TF_AUTO_APPROVE=1 make clusters
```

The cluster path is deliberately different: `clusters-plan` is the human
preview, while `make clusters` regenerates a fresh internal plan and applies
it only if the exact guarded cluster contract accepts it. It never consumes a
general saved plan; the default path rejects replacement, while any one-time
replacement requires its separate explicit flag and narrower contract.

The four roots intentionally keep separate, gitignored local state. Preserve
all four state directories for later drift checks and ordered teardown; losing
them does not authorize recreation or blind import. A production implementation
should migrate them to restricted, versioned remote state before multiple
operators or CI can apply.

If a domain is configured, `10-global` creates the Cloud DNS zone, A record,
DNS authorization, managed certificate, and certificate map. It cannot change
the registrar. Read the authoritative nameservers and delegate the domain
manually:

```bash
terraform -chdir=infra/10-global output -json dns_name_servers
```

Certificate issuance is an external asynchronous dependency. The verification
gate waits for it; do not create a self-signed fallback or commit registrar
credentials.

## 3. Build and deploy Kubernetes

The coordinated path builds both application images from the same clean full
SHA. Separate App A and App B Cloud Build files also support independent
compatible releases. Grafana uses its own evidence-image build at that SHA.

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
make build
make build-grafana GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make deploy-apps \
  APP_A_IMAGE_TAG="$RELEASE_SHA" \
  APP_B_IMAGE_TAG="$RELEASE_SHA"
```

`make deploy-apps` first applies the platform Kustomize layer to both regions.
That layer owns namespaces, Services/NEGs, service accounts, NetworkPolicies,
quotas, and RBAC. It then launches the App A and App B lanes in parallel, each
with a separate deployer identity, kubeconfig, work directory, and namespace.
The expansion gate accepts only a symmetric fresh, existing two-team, or fully
expanded platform; it rejects partial regional state.

After platform bootstrap, backward-compatible app releases are independent:

```bash
APP_A_SHA="$(git rev-parse HEAD)"
LIVE_APP_B_SHA="<compatible-deployed-app-b-sha>"
make build-app-a APP_A_IMAGE_TAG="$APP_A_SHA"
make deploy-app-a APP_A_IMAGE_TAG="$APP_A_SHA" APP_B_IMAGE_TAG="$LIVE_APP_B_SHA"

APP_B_SHA="$(git rev-parse HEAD)"
LIVE_APP_A_SHA="<compatible-deployed-app-a-sha>"
make build-app-b APP_B_IMAGE_TAG="$APP_B_SHA"
make deploy-app-b APP_A_IMAGE_TAG="$LIVE_APP_A_SHA" APP_B_IMAGE_TAG="$APP_B_SHA"
```

Run either direct lane independently. For simultaneous App A/App B changes,
use `make deploy-apps`; it runs both lanes concurrently and performs one final
aggregate gate. Do not launch both direct deploy commands concurrently because
their compatibility gates and rollback decisions could race. Breaking API
changes require expand-contract. An app deployer cannot alter the peer app or
platform objects.

## 4. Attach and verify the edge

Kubernetes must create and populate all six zonal App A NEGs before Terraform
may attach them.

```bash
make wait-negs APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make lb-plan APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
# Review the saved exact plan, then consume it within 30 minutes:
TF_AUTO_APPROVE=1 make lb \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
```

The final domain deployment has an HTTPS port-443 frontend only. There is no
port-80 redirect. App B remains a private ClusterIP reached only by local App A
Pods through NetworkPolicy plus a Google-signed audience-bound token.

## 5. Generate fresh evidence

Evidence must use the exact deployed SHA. Never relabel evidence from an older
release.

```bash
make seed-traffic APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify-bigquery APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify-cloud-observability \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify-platform-observability
make capture-observability-manifest \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-cloud \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-platform
make capture-observability-grafana-start GRAFANA_IMAGE_TAG="$RELEASE_SHA"
# Review the loopback dashboard and save evidence/08-grafana.png manually.
make capture-observability-grafana-verify GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-grafana-cleanup GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make test-failover APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make verify-error-reporting
make capture-evidence APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make plan-check ENABLE_CLOUD_ARMOR=0 ENABLE_BINARY_AUTHORIZATION=0
make secret-scan
```

Cloud Build bakes the checksum-pinned BigQuery plugin into the Grafana image,
publishes it to Artifact Registry under the release SHA, and scans it before
publication. The Job resolves that tag to one digest before rendering the
manifest; it performs no runtime plugin or Docker Hub download. It has no
Service or Ingress and expires within one hour. Cloud
Trace must show the exact App A server -> App A client -> App B server parent
chain for the current versions; Profiler must show recent current-version App A
CPU plus heap/wall metadata. Platform verification separately checks the
bounded log settings, a fresh capped BigQuery sink row, and current node, HPA,
and load-balancer signals. The phased capture commands atomically create
`18-release-manifest.txt` through `21-gke-grafana.txt`; a failed gate never
replaces retained evidence. Grafana's screenshot remains an explicit browser
step, and cleanup is mandatory even if the screenshot or verifier fails.

Generated evidence and deliverable archives, `.env`, Terraform state,
kubeconfigs, credentials, and assignment source material stay out of Git.
Cloud Armor and Binary Authorization are disabled by default and are not part
of this reproduction unless separately approved. Teardown is destructive and
must use the guarded order documented in the root README.
