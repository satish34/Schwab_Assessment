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

- Project: `schwab-assessment-gke`
- Public UI: `https://satish.store`
- Public API: `https://satish.store/api/exchange-rates`
- Edge: the managed certificate is `ACTIVE`; only HTTPS port 443 is configured.
  There is no HTTP forwarding rule, proxy, or redirect, so plain HTTP receives
  no response.
- Deployed image SHA: `cb1cba2fdc0ff997378d5ab86b6121a4f33dfa89`
- Backends: six zonal App A NEGs, with all three endpoints healthy in each
  region
- Service authentication: App A obtains a Google-signed ID token through GKE
  Workload Identity Federation; App B validates it. A direct unauthenticated
  internal request returns `401`, while authenticated calls pass in both cells.
- BigQuery: current-SHA rows cover both cells, both services, controlled
  errors, authentication denials, latency, and trace joins
- Failover: 162 requests while `us-central1` was faulted; 15 failed only during
  transition, none failed before the fault or after public convergence,
  `us-east4` served, public traffic converged in 67.804 seconds, and all six
  backends recovered
- Grafana: all four fresh currency panels passed live checks and were visually
  verified in the saved screenshot
- Error Reporting: the fresh one-hour view grouped 183 controlled App B fault
  occurrences and 58 App A dependency-failure occurrences
- Optional paid controls: Cloud Armor and Binary Authorization are implemented
  behind feature flags but disabled in the live environment. No policy is
  attached and no cluster admission enforcement is enabled.
- Terraform: all four stacks reported `NO_CHANGES`
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

## Owner-only live verification

These commands require the named Google identity. `make preflight` also needs
the ignored `.env`; cluster and data checks use ignored local Terraform/runtime
state. An interviewer should not change the admin CIDR, billing link, IAM, or
project.

```bash
make preflight
make verify IMAGE_TAG=cb1cba2fdc0ff997378d5ab86b6121a4f33dfa89
make seed-traffic IMAGE_TAG=cb1cba2fdc0ff997378d5ab86b6121a4f33dfa89
make verify-bigquery IMAGE_TAG=cb1cba2fdc0ff997378d5ab86b6121a4f33dfa89
make verify-error-reporting
```

To inspect the dashboard locally, run
`bash scripts/local-grafana-evidence.sh start`, open the printed loopback URL,
then run the same script with `cleanup`. It uses a short-lived impersonated
reader token and never creates a service-account key.

## Automation boundary

The Make targets automate formatting, tests, scans, Terraform, immutable image
builds, regional deployment, verification, traffic, BigQuery, Grafana, Error
Reporting, Cloud Armor, Binary Authorization, failover restoration, evidence,
drift checks, ordered teardown, and orphan reporting once the approved
operator inputs are present.

Human action remains intentional for Google login/MFA, billing and payment
authority, domain purchase and registrar terms, hosted-dashboard access and
reviewer identity, visual acceptance, Git publication, live-cost continuation,
and the exact destructive teardown confirmation. Project creation, apply,
publication, and teardown are technically scriptable, but this repository does
not cross those financial, access, or destructive boundaries without approval.
After an owned domain is supplied, DNS records, certificate configuration, and
issuance checks can be automated.

## Trusted HTTPS and DNS

This assessment uses the dedicated root domain `satish.store`, so Cloud DNS
becomes authoritative for the whole domain. Put only the hostname in the
ignored `.env` file:

```text
DOMAIN_NAME=satish.store
```

For a fresh rebuild, run `TF_AUTO_APPROVE=1 make bootstrap` and
`TF_AUTO_APPROVE=1 make global`. Terraform creates the Cloud DNS zone, the A
record for the reserved global IP, DNS authorization, managed certificate, and
certificate map. Read the assigned authoritative servers with:

```bash
terraform -chdir=infra/10-global output -json dns_name_servers
```

For a fresh rebuild, replace the Squarespace domain nameservers with all
returned name servers. This removes the Squarespace parking records, but
registration, privacy, renewal, and the domain lock stay at Squarespace. Do not
share registrar credentials. Public DNS, the managed certificate, and the
HTTPS-only frontend are live. Continue a fresh rebuild with:

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
make wait-negs IMAGE_TAG="$RELEASE_SHA"
make lb-plan
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

The image pipeline rejects a dirty or uncommitted tree. `make build` submits
the two application images to Cloud Build with the same full Git SHA; no
`latest` tag is used. The currency release was built and deployed from one
clean SHA. Raw capture artifacts remain outside the public source tree and old
evidence is never relabelled as proof for a new SHA.

For owner workflows, copy `.env.example` to `.env` and replace its billing and
admin-CIDR placeholders. `.env` is ignored and must never be committed.

For an owner redeployment into the existing billing-enabled project, build and
deploy the same full repository SHA throughout:

```bash
make preflight
make fmt
make test
make local-up
make local-verify
TF_AUTO_APPROVE=1 make bootstrap
TF_AUTO_APPROVE=1 make global
TF_AUTO_APPROVE=1 make clusters
make build
RELEASE_SHA="$(git rev-parse HEAD)"
make deploy-apps IMAGE_TAG="$RELEASE_SHA"
make wait-negs IMAGE_TAG="$RELEASE_SHA"
make lb-plan
TF_AUTO_APPROVE=1 make lb
make verify IMAGE_TAG="$RELEASE_SHA"
make seed-traffic IMAGE_TAG="$RELEASE_SHA"
make verify-bigquery IMAGE_TAG="$RELEASE_SHA"
make verify-error-reporting
make test-failover IMAGE_TAG="$RELEASE_SHA"
make capture-evidence IMAGE_TAG="$RELEASE_SHA"
make plan-check ENABLE_CLOUD_ARMOR=0 ENABLE_BINARY_AUTHORIZATION=0
make secret-scan
```

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
- [`docs/FINOPS_AND_SCOPE.md`](docs/FINOPS_AND_SCOPE.md): cost controls,
  security gaps, and production extensions.
- [`docs/PLAN_VS_ASSIGNMENT.md`](docs/PLAN_VS_ASSIGNMENT.md): deliberate
  differences from the assignment.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md): concise lessons with an expandable
  full chronology.
- [`CONTRACTS.md`](CONTRACTS.md): frozen cross-layer names and behavior.

## Publication safety

Before publication, Git history was rewritten to replace private billing,
administrator-IP, and unrelated-project identifiers. Author and committer
timestamps were preserved; commit hashes changed. A fresh-clone history and
secret scan passed. The assignment PDF, raw evidence, curated deliverables,
credentials, Terraform state, kubeconfig, and private notes are not published.

## Teardown warning

Teardown has not been authorized or executed. Capture evidence first. When it
is authorized, `make destroy` requires the exact confirmation
`DESTROY_CONFIRMATION=destroy-schwab-assessment-gke-keep-project` and removes
resources in dependency order while retaining the project. Never delete the
clusters before detaching the load balancer and allowing App A NEGs to be
garbage-collected.
