# Schwab Assessment

> Candidate-authored technical assessment using synthetic data. This is not an
> official Charles Schwab product, service, or production system.

This repository runs a small synthetic currency-rate board as two independent
GKE cells. Java App A serves the browser page and public GET API through one
global external Application Load Balancer. It calls only its local .NET App B,
which supplies a fixed catalog of ten demonstration snapshots. The UI moves
to the next snapshot on each refresh without sending an input. Both cells are
eligible while healthy, and no login, customer data, form, request body, or
query input is needed.

## Live status

The live App A/App B image tag is
`30fd8e9d60050f4b8cc93f25879883264a8ac30e`. Publication-only history
sanitation changed commit identifiers without changing release files; the
sole byte-identical public source commit is
[`a03a5fb1c174cdeac87638b39acc3b7c401545b0`](https://github.com/satish34/Schwab_Assessment/commit/a03a5fb1c174cdeac87638b39acc3b7c401545b0).
Release-matched checks proved the public endpoint, cell-local authenticated
calls, direct Cloud Trace export, Java Profiler, bounded platform logging, and
a private GKE-hosted Grafana evidence session.

- Project: `schwab-assessment-gke`
- Public UI: `https://satish.store`
- Public API: `https://satish.store/api/exchange-rates`
- Edge: the managed certificate is `ACTIVE`; only HTTPS port 443 is configured.
  There is no HTTP forwarding rule, proxy, or redirect, so plain HTTP receives
  no response.
- Deployed App A and App B image SHA:
  `30fd8e9d60050f4b8cc93f25879883264a8ac30e`
- Backends: six zonal App A NEGs, with all three endpoints healthy in each
  region
- Capacity: `us-central1` uses zones `b/c/f`; `us-east4` uses `a/b/c`.
  Terraform manages a 96-vCPU all-regions ceiling and a 900-GB regional SSD
  ceiling in each cell. These quotas allocate nothing and have no direct
  charge; actual resources remain billable and provider capacity is separate.
- Service authentication: App A obtains a Google-signed ID token through GKE
  Workload Identity Federation; App B validates it. A direct unauthenticated
  internal request returns `401`, while authenticated calls pass in both cells.
- Team isolation: both namespace deployers passed own-versus-peer RBAC checks;
  Dev has no production GCP or Kubernetes principal
- Controlled traffic: 318 bounded release-specific requests exercised success,
  authentication rejection, injected dependency failure, and recovery in both
  regions. Both fault settings were restored to zero before the run passed.
- Cloud Trace: one current-release trace proved the exact App A server -> App A
  client -> App B server parent chain.
- Java Profiler: current-release CPU and heap profiles were present in all six
  zones without retrieving profile payload bytes.
- Platform observability: fresh control-plane, node, HPA, load-balancer,
  VPC-flow, and firewall logs passed; sampled load-balancer rows reached the
  separate 30-day BigQuery dataset.
- Grafana: a private one-hour GKE Job returned real data for all four required
  panels through a loopback-only session, then the Job was removed.
- Error Reporting: the current view grouped the intentional App B injected
  fault and the propagated App A dependency failure. Unrelated Kubernetes
  platform groups are not application-health claims.
- Regional recovery: the retained controlled failover exercise proved bounded
  automatic drain and recovery, not zero downtime or peak survivor capacity.
- Optional paid controls: Cloud Armor and Binary Authorization are implemented
  behind feature flags but disabled in the live environment. No policy is
  attached and no cluster admission enforcement is enabled.
- Terraform drift: `10-global`, `20-cluster`, and `30-lb` reported no changes.
  `00-bootstrap` reported only an output refresh after the regional SSD quota
  grant reached 900 GB; Terraform reported no infrastructure change.
- Both regional clusters passed the focused final cluster contract with API
  server, controller, scheduler, HPA-controller, system, and workload logging.
- Teardown: not run; the environment remains live and billable

Raw evidence and the curated deliverables package are retained locally for
separate review and are intentionally excluded from the public source tree.

The public API is temporary and intended only for assessment review. Do not
send customer, payment, personal, or confidential data.

The image SHA is the release identifier. Pass it explicitly when verifying the
live release. Cloud Armor and Binary Authorization remain available as opt-in
Terraform controls, but their default flags are `0`; enabling either requires a
new cost and change review.

## Ten-minute review

No Google credentials are needed for this review.

1. Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), then review the
   verification summary in [`docs/EVIDENCE.md`](docs/EVIDENCE.md), the design
   tradeoffs, Terraform, dashboard source, and BigQuery queries.

2. Optionally run the portable source checks from Git Bash. These require the
   local build toolchain and Docker, but no cloud access:

   ```bash
   # Windows Git Bash when the tools were installed through WinGet
   export PATH="$(cygpath -u "$LOCALAPPDATA")/Microsoft/WinGet/Links:$PATH"

   make test
   bash scripts/verify-grafana.sh --static
   ```

3. Optionally review the same no-input GET flow locally:

   ```bash
   make local-up
   make local-verify
   ```

   `make local-up` prints the loopback browser URL. Open it to cycle through ten
   fixed synthetic USD rate snapshots and see the serving cell. When finished, run
   `docker compose --env-file .tmp/local-integration/compose.env down`.

The live endpoint is temporary. The public repository retains the source,
reproduction steps, and verification summary after the environment is removed.

## Release verification

Release-coupled verifiers must run from source that matches the deployed image.
The retained raw evidence is immutable-release-specific. The current proof is
bound to `30fd8e9d60050f4b8cc93f25879883264a8ac30e`; never relabel it as proof for
a different image.

After deploying a new full SHA, run the following commands from that exact
clean commit. They require the named Google identity, ignored `.env`, Terraform
state, and runtime state.

```bash
make preflight
APP_A_SHA="$(git rev-parse HEAD)"
APP_B_SHA="$APP_A_SHA"
make verify APP_A_IMAGE_TAG="$APP_A_SHA" APP_B_IMAGE_TAG="$APP_B_SHA"
make seed-traffic APP_A_IMAGE_TAG="$APP_A_SHA" APP_B_IMAGE_TAG="$APP_B_SHA"
make verify-bigquery APP_A_IMAGE_TAG="$APP_A_SHA" APP_B_IMAGE_TAG="$APP_B_SHA"
make verify-error-reporting
make verify-cloud-observability APP_A_IMAGE_TAG="$APP_A_SHA" APP_B_IMAGE_TAG="$APP_B_SHA"
make verify-platform-observability
```

The current Grafana proof used a one-hour GKE Job with no Service or Ingress;
the operator reached it only through a loopback port-forward. Its plugin was
baked into a scanned Artifact Registry image, and its explicit release-SHA tag
was resolved to one runtime digest. Build and cleanup require the same full
SHA:

```bash
make build-grafana GRAFANA_IMAGE_TAG="$APP_A_SHA"
make gke-grafana GRAFANA_IMAGE_TAG="$APP_A_SHA"
make gke-grafana-status GRAFANA_IMAGE_TAG="$APP_A_SHA"
make cleanup-gke-grafana GRAFANA_IMAGE_TAG="$APP_A_SHA"
```

## Automation boundary

The Make targets automate formatting, tests, scans, Terraform, immutable image
builds, regional deployment, verification, traffic, BigQuery, Grafana, Error
Reporting, Cloud Armor, Binary Authorization, failover restoration, evidence,
drift checks, ordered teardown, and orphan reporting once the approved
operator inputs are present.

Human action remains intentional for Google login/MFA, billing and payment
authority, domain purchase and registrar terms, hosted-dashboard identity,
visual acceptance, Git publication, live-cost continuation, and exact
destructive teardown confirmation. Automation stops at these financial,
identity, and destructive-action boundaries.
After an owned domain is supplied, DNS records, certificate configuration, and
issuance checks can be automated.

## Trusted HTTPS and DNS

This assessment uses the dedicated root domain `satish.store`, so Cloud DNS
becomes authoritative for the whole domain. Put only the hostname in the
ignored `.env` file:

```text
DOMAIN_NAME=satish.store
```

For a new empty project, first port the frozen project, operator, domain, and
identity contract as described in [`docs/REPRODUCE.md`](docs/REPRODUCE.md).
Then run `make bootstrap-plan`, review it, and run `TF_AUTO_APPROVE=1 make
bootstrap`; repeat with `make global-plan` and `TF_AUTO_APPROVE=1 make global`.
Each apply consumes the exact saved plan within its 30-minute contract.
Terraform creates the Cloud DNS zone, A record, DNS authorization, managed
certificate, and certificate map. Read the assigned authoritative servers with:

```bash
terraform -chdir=infra/10-global output -json dns_name_servers
```

For a new DNS zone, replace the Squarespace domain nameservers with all returned
name servers. This removes the Squarespace parking records, but
registration, privacy, renewal, and the domain lock stay at Squarespace. Do not
share registrar credentials. Public DNS, the managed certificate, and the
HTTPS-only frontend are live. Continue a fresh rebuild with:

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
make wait-negs IMAGE_TAG="$RELEASE_SHA"
make lb-plan
# Review the saved exact plan, then consume it within 30 minutes:
TF_AUTO_APPROVE=1 make lb
make verify IMAGE_TAG="$RELEASE_SHA"
```

The verifier waits for the managed certificate, tests the trusted HTTPS URL,
and confirms that no HTTP forwarding rule, proxy, or redirect is configured;
plain HTTP receives no response.

## Build and deploy

Prerequisites are Terraform 1.8+, gcloud, kubectl, Docker with Compose, jq,
Make, Git Bash, Java 21, .NET 8, and Python 3 with Matplotlib. The preflight
also installs a pinned GKE auth plugin under the ignored `.tools` directory
when needed.

Every cloud build rejects a dirty tree and publishes only a full Git-SHA tag;
`latest` is forbidden. `make build` uses `cloudbuild-release.yaml` for a
coordinated compatible pair. The exact prerequisites, Terraform order,
Kubernetes handoff, verification sequence, and external exceptions are in
[`docs/REPRODUCE.md`](docs/REPRODUCE.md).

After the shared platform exists, either team can use a separate clean checkout
and release without rebuilding or changing the other app:

```bash
# App A lane; LIVE_APP_B_SHA is the compatible deployed counterpart.
APP_A_SHA="$(git rev-parse HEAD)"
make build-app-a APP_A_IMAGE_TAG="$APP_A_SHA"
make deploy-app-a APP_A_IMAGE_TAG="$APP_A_SHA" APP_B_IMAGE_TAG="$LIVE_APP_B_SHA"

# App B lane; LIVE_APP_A_SHA is the compatible deployed counterpart.
APP_B_SHA="$(git rev-parse HEAD)"
make build-app-b APP_B_IMAGE_TAG="$APP_B_SHA"
make deploy-app-b APP_A_IMAGE_TAG="$LIVE_APP_A_SHA" APP_B_IMAGE_TAG="$APP_B_SHA"
```

Each compatible app can build and deploy without rebuilding or mutating the
other. For simultaneous changes, use `make deploy-apps`: it runs both app lanes
concurrently, waits for both, then runs one aggregate pair gate. Do not launch
the two direct deploy commands concurrently because each direct lane owns its
own authoritative compatibility gate and rollback. Breaking contracts use
expand-contract. A first deployment or an observability-namespace
expansion also uses `make deploy-apps` for the shared platform layer.

With the default flags, capture records that Cloud Armor and Binary
Authorization are implemented but disabled. Their live denial exercises are
deliberately not run. Enabling either control is a separate, paid change that
must first pass its documented Terraform and safety gates.

Do not apply `30-lb` before Kubernetes has created and populated all six zonal
NEGs. The final edge uses the active Certificate Manager map and exposes only
HTTPS port 443; plain HTTP is not redirected because there is no port 80
frontend.

## Verification and decisions

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): request flow, cell health,
  failover, ownership, and blast radius.
- [`docs/EVIDENCE.md`](docs/EVIDENCE.md): requirement-to-command verification
  summary and the names of locally retained raw artifacts.
- [`docs/BIGQUERY.md`](docs/BIGQUERY.md): exported table schema, checked-in
  analysis SQL, and Grafana query mapping.
- [`docs/FINOPS_AND_SCOPE.md`](docs/FINOPS_AND_SCOPE.md): cost controls,
  security gaps, and production extensions.
- [`docs/ASSIGNMENT_ALIGNMENT.md`](docs/ASSIGNMENT_ALIGNMENT.md): deliberate
  differences from the assignment.
- [`docs/REPRODUCE.md`](docs/REPRODUCE.md): concise rebuild and verification
  runbook, including external prerequisites and exceptions.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md): concise lessons with an expandable
  full chronology.
- [`CONTRACTS.md`](CONTRACTS.md): frozen cross-layer names and behavior.

## Repository hygiene

The assignment PDF, raw evidence, curated deliverables, credentials, Terraform
state, kubeconfigs, and local notes are excluded from version control. The
secret scan covers the tracked tree and reachable history.

## Teardown warning

Teardown has not been authorized or executed. Capture evidence first. When it
is authorized, `make destroy` requires the exact confirmation
`DESTROY_CONFIRMATION=destroy-schwab-assessment-gke-keep-project` and removes
resources in dependency order while retaining the project. Never delete the
clusters before detaching the load balancer and allowing App A NEGs to be
garbage-collected.
