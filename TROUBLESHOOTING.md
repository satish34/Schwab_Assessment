# Troubleshooting timeline

This is a chronological, evidence-based record. Never include credentials,
tokens, service-account private keys, kubeconfig, Terraform state, or
authorization headers.

Each real issue uses this template:

```text
## YYYY-MM-DD HH:MM TZ - Short symptom

Command/operation:
Symptom:
Hypothesis:
Change/decision:
Verification:
Outcome:
```

Gate 0 entries begin with the first preflight command.

## 2026-08-08 19:31 CDT - Current gcloud project is not a safe assessment target

Command/operation:
`gcloud auth list --filter=status:ACTIVE --format=value(account)` and
`gcloud config get-value project`, followed by presence-only checks for the
required environment variables.

Symptom:
The active identity is the Firebase service account
`example-service-account@unrelated-project.iam.gserviceaccount.com`, the
configured project is `unrelated-project`, and `PROJECT_ID`,
`BILLING_ACCOUNT_ID`, and `ADMIN_CIDR` are not set.

Hypothesis:
The active gcloud context belongs to an existing application project and is
not a dedicated, disposable assessment project. Using it would make the
required teardown unsafe and the service account may also lack project,
billing, IAM, budget, and GKE administration permissions.

Change/decision:
No cloud mutation was attempted. Inventory existing gcloud configurations and
accessible projects for a dedicated alternative; otherwise obtain or create a
dedicated billing-enabled project under an authorized human/automation
identity.

Verification:
Gate 0 remains current until project isolation, billing, permissions, quota,
and the admin CIDR are verified.

Outcome:
Resolved. A separate gcloud configuration named `schwab-assessment` now uses
`satish.cse7@gmail.com` and targets the new dedicated project
`schwab-assessment-gke`; the unrelated default configuration was not changed.

## 2026-08-08 19:40 CDT - Background OAuth launcher rejected locally

Command/operation:
Attempted to start `gcloud auth login satish.cse7@gmail.com` in a hidden,
separate process under a named gcloud configuration.

Symptom:
The command wrapper was rejected by the local execution policy before the
PowerShell script ran.

Hypothesis:
The combined hidden-process command and nested command-shell quoting triggered
the local command safety filter.

Change/decision:
Do not retry the same launcher. Use a simpler foreground gcloud OAuth flow and
keep the assessment configuration isolated by name.

Verification:
No OAuth process was started and no Google Cloud resource or account setting
changed.

Outcome:
Resolved. OAuth completed under the separate `schwab-assessment`
configuration with `satish.cse7@gmail.com` active.

## 2026-08-08 19:44 CDT - Google Cloud rejected underscore in display name

Command/operation:
`gcloud projects create schwab-assessment-gke --name=Schwab_Assessment`
under the isolated `schwab-assessment` configuration with
`satish.cse7@gmail.com` active.

Symptom:
Cloud Resource Manager returned `INVALID_ARGUMENT` because the project display
name contained an invalid character.

Hypothesis:
Google Cloud project display names do not accept underscore characters.

Change/decision:
Keep the repository folder named `Schwab_Assessment`, use the valid Google
Cloud display name `Schwab Assessment`, and retain the clean project ID
`schwab-assessment-gke`.

Verification:
Retry project creation with the valid display name, then describe the created
project by its explicit ID.

Outcome:
Resolved. Project `schwab-assessment-gke` was created successfully with the
valid display name `Schwab Assessment`; the rejected request created no extra
project.

## 2026-08-08 19:46 CDT - Project owner cannot associate billing account

Command/operation:
`gcloud billing projects link schwab-assessment-gke` under the isolated
`schwab-assessment` configuration with `satish.cse7@gmail.com` active.

Symptom:
The project exists and is active, but Cloud Billing denied
`billing.resourceAssociations.create`; verification showed
`billingEnabled: false`. A following config-display command also used an
invalid argument form, but setting the named configuration's project itself
succeeded.

Hypothesis:
Project ownership and billing-account association are separate permissions.
The requested account owns the new project but has not yet been granted access
to associate projects with the existing billing account or manage its budget.

Change/decision:
From the existing billing administrator, grant
`user:satish.cse7@gmail.com` only `roles/billing.user` and
`roles/billing.costsManager` on the billing account. Retry the project link as
the requested account and use the corrected config verification syntax.

Verification:
Describe the link and require `billingEnabled: true`; list the active account
and project from the isolated configuration.

Outcome:
Resolved. The least-privilege billing bindings were added and the project now
reports `billingEnabled: true`.

## 2026-08-08 19:47 CDT - Billing IAM command used unsupported flag

Command/operation:
Two `gcloud billing accounts add-iam-policy-binding` calls included
`--condition=None`.

Symptom:
Both calls rejected the unsupported argument. PowerShell did not automatically
stop on the native nonzero exit codes and printed a later success marker even
though neither binding had been applied.

Hypothesis:
The billing-account IAM command has a narrower flag surface than project IAM,
and native command failures require explicit `$LASTEXITCODE` checks in this
Windows shell.

Change/decision:
Remove the unsupported flag, check each native exit code immediately, and
verify the resulting policy bindings before retrying billing association.

Verification:
Filter the billing-account IAM policy for `user:satish.cse7@gmail.com` and
require both intended roles.

Outcome:
Resolved. The corrected calls succeeded, and policy verification returned both
`roles/billing.user` and `roles/billing.costsManager` for the requested
account. The failed calls changed no IAM policy.

## 2026-08-08 19:51 CDT - Non-elevated Chocolatey install failed

Command/operation:
Attempted noninteractive Chocolatey installation of GNU Make and Maven.

Symptom:
Chocolatey reported that the shell was not elevated, timed out at its
confirmation prompt, and could not acquire/write its package directories.
Neither package was installed by that command.

Hypothesis:
The machine-wide Chocolatey installation requires administrator elevation,
which is unnecessary for this repository when user-level or containerized
tools are available.

Change/decision:
Install GNU Make 4.4.1 through the user-level winget package and use the pinned
`maven:3.9.11-eclipse-temurin-21` container for Java builds.

Verification:
`make --version` returns 4.4.1 and the pinned Maven container returns Maven
3.9.11 on Java 21.

Outcome:
Resolved without elevation.

## 2026-08-08 19:54 CDT - Optional .NET 8 SDK installer waited on elevation

Command/operation:
Attempted a silent winget installation of Microsoft .NET SDK 8.0.

Symptom:
The machine-level installer remained idle awaiting elevation and did not add an
SDK. The installer processes were cancelled; `dotnet --list-sdks` remained at
9.0.304.

Hypothesis:
Installing the additional machine-wide SDK requires administrator approval,
but the existing .NET 9 SDK supports targeting `net8.0` and the .NET 8 runtime
and targeting assets are already available.

Change/decision:
Do not require elevation. Prove compatibility by generating and compiling a
temporary `net8.0` project with the existing SDK.

Verification:
The temporary `net8.0` Release build completed with zero warnings and zero
errors.

Outcome:
Resolved; the repository can build its required .NET 8 application. After the
user approved elevation, winget also installed the native .NET 8 SDK 8.0.408;
`dotnet --list-sdks` now shows both 8.0.408 and 9.0.304.

## 2026-08-08 19:56 CDT - Host bq CLI has Cloud SDK ACL corruption

Command/operation:
Ran `bq version` and inspected the failing bundled Python package paths and
their ACL boundaries.

Symptom:
The host `bq` 2.1.17 fails before authentication with access denied under
multiple bundled dependencies, including `absl/flags`. The current
non-elevated session cannot repair those SDK directories safely.

Hypothesis:
This is broad Google Cloud SDK installation ACL corruption, not a project,
authentication, or BigQuery configuration error.

Change/decision:
Do not mutate machine-wide ACLs. Use a pinned Google Cloud CLI container for
`bq` operations; a future elevated Cloud SDK repair is optional host
maintenance and not an assessment dependency.

Verification:
Require the pinned container to return its `bq` version before Gate 0 closes.

Outcome:
Resolved. The pinned `google-cloud-cli:525.0.0-slim` container returned
BigQuery CLI 2.1.17 successfully. A later `gcloud alpha bq --help` check also
confirmed that this non-elevated SDK cannot install optional components, so the
container decision remains unchanged.

## 2026-08-08 20:11 CDT - Budget notification block failed validation

Command/operation:
`terraform validate` for `infra/00-bootstrap` with Google provider 7.43.0.

Symptom:
The provider requires `all_updates_rule` to include a Pub/Sub topic or
Monitoring notification channel. Setting only the default-IAM-recipient flag
was invalid.

Hypothesis:
Default billing-recipient email alerts do not need an `all_updates_rule` block;
that block configures an additional notification delivery path.

Change/decision:
Remove the empty delivery rule and keep the four threshold rules. Do not add an
unused Pub/Sub topic merely to satisfy the schema.

Verification:
Rerun Terraform formatting, validation, and plan.

Outcome:
Resolved. Validation passed after the block was removed; the corrected plan
contains the four budget thresholds.

## 2026-08-08 20:12 CDT - PowerShell split Terraform variable arguments

Command/operation:
Ran a manual PowerShell `terraform plan` with inline repeated `-var=...`
arguments.

Symptom:
Terraform reported too many positional arguments before reading the
configuration.

Hypothesis:
PowerShell's native argument handling changed the intended Terraform argument
boundaries.

Change/decision:
Run Terraform through the checked-in Bash wrapper, which passes each variable
as one array element and is the same path used by the Make target.

Verification:
Run `scripts/terraform-stack.sh infra/00-bootstrap plan`.

Outcome:
Resolved. The Bash wrapper produced a clean plan: 13 additions, zero changes,
and zero destroys.

## 2026-08-08 20:34 CDT - PowerShell did not expand an `rg` glob

Command/operation:
Checked that exactly one BigQuery SQL file uses `APPROX_QUANTILES`.

Symptom:
`rg` received the literal `*.sql` path and returned no matches.

Hypothesis:
PowerShell does not expand that native-command glob in this context.

Change/decision:
Pass the containing directory to `rg` and let it recurse.

Verification and outcome:
The corrected check found exactly one quantiles query; all four SQL contract
checks passed.

## 2026-08-08 20:41 CDT - App B test wiring and assertions failed

Command/operation:
`dotnet test AppB.sln -c Release` during the first App B verification cycle.

Symptom:
The test project first lacked xUnit imports. Two compiled tests then compared a
list by reference and reused a valid trace header. Pinning .NET 8 also exposed a
missing `Microsoft.Extensions.Configuration` import.

Hypothesis:
The hand-created test project needed explicit imports, and the two assertions
did not test the intended values or invalid-header path.

Change/decision:
Add the xUnit and configuration imports, compare record fields and sequences,
and isolate the invalid trace-header request.

Verification and outcome:
Resolved. All 34 App B tests pass, including scoring thresholds, rule deltas,
and ERROR-log schema coverage. The Release build has zero warnings and errors.

## 2026-08-08 20:54 CDT - Project import needed the Cloud Billing API

Command/operation:
First committed `make global` apply.

Symptom:
Terraform imported the existing project, then stopped with HTTP 403 while
confirming its billing account because `cloudbilling.googleapis.com` was
disabled. No foundation resource was created. The first follow-up state command
also missed Terraform because this parent shell predates the WinGet PATH update.

Hypothesis:
Managing the billing field on an imported `google_project` requires the Cloud
Billing API even when the link already exists.

Change/decision:
Add the API to `00-bootstrap`; keep the imported project in local state. Prefix
this process's PATH with the verified WinGet link for Terraform commands.

Verification:
Apply `00-bootstrap`, confirm only `google_project.current` is in global state,
then rerun `make global` and its live verifier.

Outcome:
Resolved. Bootstrap enabled the API and passed its budget verifier. The next
global apply completed 25 additions and one project update with zero destroys;
the separate default-VPC verification issue is recorded below.

## 2026-08-08 21:02 CDT - Imported project kept its default VPC

Command/operation:
`make global`, including the post-apply `scripts/verify-global.sh` gate.

Symptom:
Terraform applied the global foundation, but verification found both `default`
and `risk-vpc` instead of only `risk-vpc`.

Hypothesis:
The imported project stored `auto_create_network = false` without deleting the
network. The pinned provider source confirmed that deletion runs only in the
project create path, not the update path used after import.

Change/decision:
Add a one-time Terraform cleanup resource. Its script checks the exact account,
project, auto-network signature, standard firewall names, and VM use, and
refuses customized targets before removing anything.

Verification:
The read-only cleanup check passed. Terraform format and validation passed, and
the plan is one cleanup resource to add with zero changes or destroys.

Outcome:
Resolved. The standard default firewall rules and auto-created VPC were
removed. The complete live verifier passed, and both bootstrap and global
Terraform plans now report no changes.

## 2026-08-08 21:03 CDT - Login Bash could not find jq

Command/operation:
Ran the default-network safety check through a Git Bash login shell.

Symptom:
The script stopped at its first `jq` call because that shell did not include
the user-level WinGet links directory.

Hypothesis:
This Codex process predates the jq install, and the login shell rebuilt PATH.

Change/decision:
Prefix the verified WinGet links directory and use the same non-login Git Bash
mode as the Make workflow. No repository logic changed.

Verification and outcome:
Resolved. Bash syntax checks passed and the safety check verified the unused
default VPC without making a cloud change.

## 2026-08-08 21:07 CDT - Noninteractive Terraform apply reached EOF

Command/operation:
`make global` after the cleanup plan passed.

Symptom:
Terraform requested approval but had no interactive input, then exited before
making a change.

Hypothesis and change:
The wrapper requires its explicit `TF_AUTO_APPROVE=1` automation switch. Set it
for the already-reviewed apply.

Verification and outcome:
Resolved. The rerun accepted the reviewed plan; the first attempt changed
nothing.

## 2026-08-08 21:08 CDT - Windows line ending entered firewall names

Command/operation:
Terraform's guarded default-network cleanup provisioner.

Symptom:
gcloud rejected each standard firewall name because raw `jq.exe` output left a
carriage return at the end. It deleted no firewall or network.

Hypothesis and change:
The Windows jq pipe used CRLF. Normalize the parsed name array and validate each
name before the first delete.

Verification and outcome:
Resolved. The read-only check passed, then Terraform removed only the four
standard rules and the verified auto-created default VPC.

## 2026-08-08 21:10 CDT - Reserved IPv4 omitted an optional API field

Command/operation:
Post-apply `scripts/verify-global.sh`.

Symptom:
The address was live with status `RESERVED`, but the verifier rejected it
because the JSON response omitted `ipVersion` for the default IPv4 case.

Hypothesis and change:
Treat an absent version as IPv4 while also validating the address text and
reserved/in-use status.

Verification and outcome:
Resolved. The full live verifier passed, followed by zero-change plans for
`00-bootstrap` and `10-global`.

## 2026-08-08 21:11 CDT - Terraform format diff tool was missing from PATH

Command/operation:
`terraform -chdir=infra/20-cluster fmt -recursive -check -diff`.

Symptom:
Terraform could not launch `diff` from the inherited PowerShell PATH.

Hypothesis and change:
The current process predates the Git tooling PATH update. Add Git's `usr/bin`
directory for this validation process; do not change the Terraform files.

Verification and outcome:
Resolved. The format diff check and `terraform validate` both passed.

## 2026-08-08 21:23 CDT - GKE rejected duplicate telemetry settings

Command/operation:
First committed `make clusters` apply.

Symptom:
Both cluster create requests returned HTTP 400 because the modern logging and
monitoring component blocks were sent with their legacy service fields. No
cluster was created; only the local Terraform contract marker entered state.

Hypothesis and change:
The API treats the legacy service fields and modern component blocks as
mutually exclusive even though provider validation allowed both. Remove the
two legacy fields and retain the explicit SYSTEM/WORKLOAD components.

Verification:
Confirm live cluster inventory is still empty, then rerun format, validation,
the two-cluster plan, and the committed apply.

Outcome:
Resolved. Both regional Autopilot clusters were created, the complete live
contract verifier passed, and the final refreshed plan reports no changes.

## 2026-08-08 21:24 CDT - App A startup tests exposed two bean wiring errors

Command/operation:
First pinned Maven verification runs for App A.

Symptom:
Spring first found a duplicate `requestContextFilter` bean name. After that was
fixed, it found two possible `CellHealthState` constructors.

Hypothesis and change:
The application filter collided with Spring Boot's bean, and a public test
constructor made dependency injection ambiguous. Rename the filter and replace
the constructor with a test-only factory.

Verification and outcome:
Resolved. The application context starts and the focused tests pass.

## 2026-08-08 21:25 CDT - App A smoke check used unreliable host-port polling

Command/operation:
First read-only container smoke checks for App A.

Symptom:
The first poll received an empty reply, and a fixed-port retry found port 18080
already allocated even though the container itself was healthy.

Hypothesis and change:
The validator assumed both immediate startup and a free fixed host port. Use a
bounded readiness poll and Docker's random host-port allocation.

Verification and outcome:
Resolved. Non-root, read-only runtime checks returned the expected live, ready,
and initial cell-health statuses.

## 2026-08-08 21:26 CDT - App A review found security and response-contract gaps

Command/operation:
Independent source, runtime-log, API, and image review.

Symptom:
The first draft used vulnerable Tomcat/runtime packages, emitted some framework
logs outside the frozen schema, accepted a missing downstream score, mapped
unsupported media to 503, and let probe starts drift past the two-second
cadence.

Hypothesis and change:
Defaults did not fully satisfy the explicit assessment contract. Upgrade the
patched dependency/runtime graph and add focused validation, logging, error
mapping, and fixed-rate probe tests.

Verification:
Repeat Maven tests, read-only runtime/API checks, physical-line log-schema
checks, and the critical/high image scan after the final review corrections.

Outcome:
Resolved. The patched graph uses Spring Boot 3.5.16 and Tomcat 10.1.57. All 31
tests pass; the read-only runtime emitted 20 of 20 physical lines in the exact
schema, and both dependency and whole-image scans report zero critical/high
findings.

## 2026-08-08 21:22 CDT - New load-balancer HCL needed formatting

Command/operation:
Initial `terraform fmt -check -recursive` for `infra/30-lb`.

Symptom and change:
The new `main.tf` was not yet normalized. Run `terraform fmt -recursive` and
then repeat the check.

Verification and outcome:
Resolved. Format, initialization, validation, and the independent review pass.

## 2026-08-08 21:26 CDT - Load-balancer review guessed the wrong Service file

Command/operation:
Read `k8s/base/app-a-service.yaml` while checking the NEG contract.

Symptom and change:
That guessed path does not exist. Repository search located both Services in
`k8s/base/services.yaml`; no source change was needed.

Verification and outcome:
Resolved. The reviewer used the discovered manifest and completed the check.

## 2026-08-08 21:36 CDT - State-only cluster apply needed explicit approval

Command/operation:
First noninteractive apply of provider-normalized cluster output values.

Symptom:
Terraform reached EOF at its approval prompt and changed nothing.

Hypothesis and change:
The repository wrapper intentionally requires `TF_AUTO_APPROVE=1` for a
reviewed noninteractive apply. Set it only for the output-only action.

Verification and outcome:
Resolved. Terraform reported zero resources added, changed, or destroyed; the
live verifier passed and the follow-up plan reports no changes.

## 2026-08-08 21:39 CDT - Local integration review used the wrong plan path

Command/operation:
Read `GKE_Assessment_Plan.md` from the repository root.

Symptom and change:
The file is not stored there. Use its authoritative path,
`<local-assessment-plan>`, instead; no repository file changed.

Verification and outcome:
Resolved. The full local-test section was read from the correct source before
the Compose workflow was written.

## 2026-08-08 21:42 CDT - Scoped advice missed early media negotiation errors

Command/operation:
First Maven pass after adding explicit App A `consumes` and `produces` rules.

Symptom:
Three of 31 tests failed. Spring rejected unsupported request/response media as
415/406 before selecting `RiskController`, so controller-scoped advice could
not apply because the handler was null.

Hypothesis and change:
Handler selection happened earlier than the advice scope. Restore controller
selection for unsupported request content and reject an incompatible `Accept`
header deterministically in the `/v1/risk` filter.

Verification and outcome:
Resolved. The pinned Maven pass now has 31 passing tests. Unsupported content
types and `Accept: text/plain` both return 400 without calling App B; the latter
correctly has an empty body because the client refused JSON.
