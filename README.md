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
- Reserved public edge: `http://136.69.29.22`
- Trusted hostname: `satish.store` (public DNS propagated and managed
  certificate active; HTTPS frontend pending)
- Deployed image SHA: `4151c68e57968ea4b56acc56e8b5f443f7617970`
- Edge: six healthy App A endpoints across `us-central1` and `us-east4`
- Data: structured App A/App B rows and all four queries verified in BigQuery
- Failover: passed with `us-central1` faulted and `us-east4` serving; 16 of 167
  requests failed during the measured drain window, then all six backends
  recovered
- Grafana: all four panels passed live API checks and were visually verified
  in a loopback-only Grafana 13.1.0 session; evidence is in
  `evidence/08-grafana.png`
- Error Reporting: controlled App A and App B exceptions are grouped in Google
  Cloud; evidence is in `evidence/11-error-reporting.png`
- Teardown: not run; the environment remains live and billable

The live environment and saved evidence still belong to the earlier deployed
application release. The GET-only currency board must be released as one clean
immutable SHA. After rollout, every live check and evidence artifact must be
regenerated before this section claims the new release.

The public API is temporary and intended only for assessment review. Do not
send customer, payment, personal, or confidential data.

The deployed image SHA is a release identifier, not the current repository
HEAD. Later infrastructure, verification, and documentation commits do not
change the running containers. Use `git rev-parse HEAD` to inspect the current
repository version, and pass the deployed SHA explicitly when verifying the
live release.

## Ten-minute review

No Google credentials are needed for this review.

1. Start with [`docs/EVIDENCE.md`](docs/EVIDENCE.md), then inspect the linked
   architecture, dashboard, error, BigQuery, and failover artifacts.

2. Optionally run the portable source checks from Git Bash. These require the
   local build toolchain and Docker, but no cloud access:

   ```bash
   # Windows Git Bash when the tools were installed through WinGet
   export PATH="$(cygpath -u "$LOCALAPPDATA")/Microsoft/WinGet/Links:$PATH"

   make test
   bash scripts/verify-grafana.sh --static
   ```

3. Review the new no-input GET flow locally before it is released:

   ```bash
   make local-up
   make local-verify
   ```

   `make local-up` prints the loopback browser URL. Open it to cycle through ten
   fixed synthetic USD rate snapshots and see the serving cell. When finished, run
   `docker compose --env-file .tmp/local-integration/compose.env down`.

The live endpoint is temporary. The evidence remains reviewable after it is
removed.

## Owner-only live verification

These commands require the named Google identity. `make preflight` also needs
the ignored `.env`; cluster and data checks use ignored local Terraform/runtime
state. An interviewer should not change the admin CIDR, billing link, IAM, or
project.

```bash
make preflight
make verify IMAGE_TAG=4151c68e57968ea4b56acc56e8b5f443f7617970
make seed-traffic IMAGE_TAG=4151c68e57968ea4b56acc56e8b5f443f7617970
make verify-bigquery IMAGE_TAG=4151c68e57968ea4b56acc56e8b5f443f7617970
make verify-error-reporting
```

To inspect the dashboard locally, run
`bash scripts/local-grafana-evidence.sh start`, open the printed loopback URL,
then run the same script with `cleanup`. It uses a short-lived impersonated
reader token and never creates a service-account key.

## Automation boundary

The Make targets automate formatting, tests, scans, Terraform, immutable image
builds, regional deployment, verification, traffic, BigQuery, Grafana, Error
Reporting, failover restoration, evidence, drift checks, ordered teardown, and
orphan reporting once the approved operator inputs are present.

Human action remains intentional for Google login/MFA, billing and payment
authority, domain purchase and registrar terms, hosted-dashboard access and
reviewer identity, visual acceptance, Git publication, live-cost continuation,
and the exact destructive teardown confirmation. Project creation, apply,
publication, and teardown are technically scriptable, but this repository does
not cross those financial, access, or destructive boundaries without approval.
After an owned domain is supplied, DNS records, certificate configuration, and
issuance checks can be automated.

## Trusted HTTPS after buying a domain

This assessment uses the dedicated root domain `satish.store`, so Cloud DNS
becomes authoritative for the whole domain. Put only the hostname in the
ignored `.env` file:

```text
DOMAIN_NAME=satish.store
```

After approval, run `TF_AUTO_APPROVE=1 make bootstrap` and
`TF_AUTO_APPROVE=1 make global`. Terraform creates the Cloud DNS zone, the A
record for the reserved global IP, DNS authorization, managed certificate, and
certificate map. Read the assigned authoritative servers with:

```bash
terraform -chdir=infra/10-global output -json dns_name_servers
```

For a fresh rebuild, replace the Squarespace domain nameservers with all
returned name servers. This removes the Squarespace parking records, but
registration, privacy, renewal, and the domain lock stay at Squarespace. Do not
share registrar credentials. The assessment domain was switched on August 9,
2026, and both public DNS and the managed certificate are ready. After the
approved currency release is deployed, run:

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
make wait-negs IMAGE_TAG="$RELEASE_SHA"
make lb-plan
TF_AUTO_APPROVE=1 make lb
make verify IMAGE_TAG="$RELEASE_SHA"
```

The verifier waits for the managed certificate, tests the trusted HTTPS URL,
and confirms that the public address has no port 80 listener.

## Build and deploy

Prerequisites are Terraform 1.8+, gcloud, kubectl, Docker with Compose, jq,
Make, Git Bash, Java 21, .NET 8, and Python 3 with Matplotlib. The preflight
also installs a pinned GKE auth plugin under the ignored `.tools` directory
when needed.

The image pipeline rejects a dirty or uncommitted tree. The release therefore
uses two approval points: first approve a small set of focused source and
automation commits, then build and deploy that clean SHA. After all live checks
are rerun, separately approve the refreshed evidence/documentation closeout
commit and private reviewer-repository publication. Old evidence is never
relabelled as proof for the new SHA.

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
make plan-check
make secret-scan
```

Do not apply `30-lb` before Kubernetes has created and populated all six zonal
NEGs. The existing HTTP deployment predates the domain; the ready Certificate
Manager map is applied only after the approved currency release is serving.
That apply removes the old port 80 frontend; the final public edge is HTTPS
only.

## Evidence and decisions

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): request flow, cell health,
  failover, ownership, and blast radius.
- [`docs/EVIDENCE.md`](docs/EVIDENCE.md): requirement-to-command-to-artifact
  index, including open gates.
- [`docs/FINOPS_AND_SCOPE.md`](docs/FINOPS_AND_SCOPE.md): cost controls,
  security gaps, and production extensions.
- [`docs/PLAN_VS_ASSIGNMENT.md`](docs/PLAN_VS_ASSIGNMENT.md): deliberate
  differences from the assignment.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md): concise lessons with an expandable
  full chronology.
- [`CONTRACTS.md`](CONTRACTS.md): frozen cross-layer names and behavior.

## Teardown warning

Teardown has not been authorized or executed. Capture evidence first. When it
is authorized, `make destroy` requires the exact confirmation
`DESTROY_CONFIRMATION=destroy-schwab-assessment-gke-keep-project` and removes
resources in dependency order while retaining the project. Never delete the
clusters before detaching the load balancer and allowing App A NEGs to be
garbage-collected.
