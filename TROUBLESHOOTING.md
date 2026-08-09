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

## 2026-08-08 21:52 CDT - Docker Desktop did not allocate an empty host port

Command/operation:
First `make local-up` and two isolated Docker port-allocation probes.

Symptom:
Both services became healthy, but Compose published no App A port. An explicit
OS-selected port rendered correctly but was also suppressed. Two early CLI
probes used `--network none`, so they could not prove port publishing; a broad
range probe also selected a Windows-reserved port.

Hypothesis and change:
This Docker Desktop build suppresses published ports for a container attached
only to an internal Compose network. A control probe on the normal bridge
published the same loopback binding. Keep App B without any host port, use the
normal private project bridge, and publish only App A to an OS-selected
`127.0.0.1` port.

Verification:
Rerun `make local-up`, require a `127.0.0.1:<port>` binding, then run the full
local verifier.

Outcome:
Resolved. App A is published only on `127.0.0.1:53173`; App B has no host port,
and both services are healthy on the project bridge.

## 2026-08-08 21:55 CDT - Git Bash rewrote an in-container `/dev/tcp` path

Command/operation:
First `make local-verify` and its focused trace.

Symptom:
The verifier exited at App B's first direct health check even though the same
container command passed from PowerShell and Compose health remained green. A
follow-up nested-quote diagnostic was rejected by PowerShell before execution.

Hypothesis and change:
Git Bash path conversion rewrote `/dev/tcp/...` while passing the command
through `docker.exe`. Disable MSYS path conversion for that one `docker exec`
and attach an explicit failure message.

Verification:
Rerun the complete local verifier from its Make target.

Outcome:
Resolved. The Make target completed the full health, request, trace, log, fault,
and recovery verification.

## 2026-08-08 21:57 CDT - Make rewrote Maven's container work directory

Command/operation:
First repository-wide `make fmt`.

Symptom:
Docker rejected `C:/Program Files/Git/workspace`; Git Bash had converted the
intended in-container `/workspace` argument. The formatter never started and no
source changed. A later Make PATH check also showed that `$(shell cygpath)` was
launched before Make could resolve `cygpath` on Windows. One direct Terraform
output probe likewise used the stale parent PATH before its corrected rerun.

Hypothesis and change:
This is the same MSYS-to-`docker.exe` argument conversion seen in the local
health check. Disable path conversion only for the two Maven container calls,
and export the existing Windows WinGet path without a subprocess.

Verification:
Rerun `make fmt` and `make test` through the checked-in Makefile.

Outcome:
Resolved. `make fmt` and `make test` pass; Java has 31 passing tests and .NET
has 34, with both Kubernetes overlays rendering successfully.

## 2026-08-08 21:58 CDT - Image workflow checks made Windows and SDK assumptions

Command/operation:
Offline Cloud Build parsing and source-manifest validation.

Symptom:
The review first guessed a nonexistent `infra/10-global/main.tf`; the offline
parser missed the SDK's `third_party` path, and a broad SDK search hit protected
subtrees. Git Bash also missed the WinGet `jq` link. The upload manifest used
backslashes and legitimately included `.env.example`; a review-only
`--ignore-file` flag was unsupported. Two temporary-tar smoke commands were
blocked before execution by shell policy.

Hypothesis and change:
The checks assumed Unix paths and a monolithic Terraform file. Discover the
split files, load the exact SDK module path, narrow the search, normalize
manifest separators, allow only `.env.example`, use `.gcloudignore`
automatically, and replace tar probes with safe scanner/socket checks.

Verification and outcome:
Resolved. The Cloud Build config parses as nine steps and two images; all
pinned images resolve, Bash syntax passes, and the 149-file upload manifest
contains the required sources with no state, credentials, or Git internals.

## 2026-08-08 21:59 CDT - Strict Trivy data included unfixed Debian findings

Command/operation:
HIGH/CRITICAL scans of both final local images with Trivy 0.73.0.

Symptom:
App A had no HIGH/CRITICAL findings. App B's current Debian base reported 17
HIGH and five CRITICAL OS findings, all marked without a vendor fixed version;
its .NET packages had none.

Hypothesis and change:
Different scanners classify deferred base-OS advisories differently. Keep the
current patched Microsoft image and block every HIGH/CRITICAL issue that has a
vendor fix with Trivy's `--ignore-unfixed`; retain the unresolved count in the
record instead of claiming a clean strict scan.

Verification and outcome:
Resolved for the publish gate. Both images pass the fix-available
HIGH/CRITICAL check; App A also passes the strict check.

## 2026-08-08 22:00 CDT - Regional-script fixtures hit shell-specific parsing

Command/operation:
Static jq and safety fixtures for the regional deployment scripts.

Symptom:
The first jq fixture lacked the WinGet link, a nested `bash -c` program was
rejected by PowerShell quoting, and an `rg` lookahead failed without PCRE2.

Hypothesis and change:
The fixture commands crossed three parser conventions. Prefix the verified jq
path, run the JSON pipeline natively, and use `rg --pcre2` for lookaround.

Verification and outcome:
Resolved. All fixtures, Bash syntax, manifest rendering, and safety scans pass;
no cluster or cloud mutation occurred.

## 2026-08-08 22:05 CDT - Edge review guessed three repository paths

Command/operation:
Required-input review and focused jq fixtures for the load-balancer verifier.

Symptom:
Reads for a repo-local plan, `testdata/expected-response.json`, and
`k8s/base/runtime-config.yaml` failed. The focused jq invocation also lacked the
WinGet link on its first PowerShell run.

Hypothesis and change:
The plan is external, the canonical request is the only response oracle, and
Kustomize generates `runtime-config`. Use those actual sources and prepend the
verified WinGet tool path for the fixture.

Verification and outcome:
Resolved. The corrected jq contract fixture, Bash syntax, and both Terraform
validations pass without a NEG query or cloud mutation.

## 2026-08-08 22:17 CDT - Commit guard matched the notebook ignore rule

Command/operation:
First delivery-workflow milestone commit attempt.

Symptom:
The private-material guard matched the new `.gitignore` line that names the
interview notebook and stopped before committing. The staged filename list did
not contain the private file.

Hypothesis and change:
The content pattern could not distinguish an ignore rule from a staged private
path. Check staged filenames for `.private/` separately and reserve content
patterns for actual keys, tokens, and the private assignment name.

Verification and outcome:
Resolved after the guarded rerun; the interview notebook remains ignored and
unstaged.

## 2026-08-08 22:22 CDT - Short command timeout stopped the build launcher

Command/operation:
First `make build` invocation through the command runner.

Symptom:
The runner stopped the local launcher after about five seconds. Cloud Build
listed no submitted build.

Hypothesis and change:
The launcher needs a long-lived yielded process while it audits and uploads the
source. Check the live build list before retrying, then use the long timeout.

Verification and outcome:
Resolved. The build list was empty, so no duplicate build was created; the
second invocation reached source upload.

## 2026-08-08 22:23 CDT - Dedicated builder could not read staged source

Command/operation:
Cloud Build submission for commit `7245354`.

Symptom:
The source archive uploaded, but submission returned 403 because
`risk-cloud-build` lacked `storage.objects.get` on the default source bucket.

Hypothesis and change:
The custom execution identity had logging and registry permissions but not
source-bucket access. Adopt the generated bucket into Terraform, enforce
uniform private access, grant that identity bucket-scoped Object Viewer, and
make the submit command use this exact managed staging path.

Verification and outcome:
Resolved. The bucket verifier and zero-drift plan pass. Cloud Build
`1d12c677-f18e-478c-bacc-d241172783b6` succeeded, and both immutable image
digests passed independent registry verification.

## 2026-08-08 22:24 CDT - Troubleshooting read used the wrong directory

Command/operation:
Read the recent troubleshooting entries while preparing the build-IAM fix.

Symptom:
`docs/TROUBLESHOOTING.md` did not exist.

Hypothesis and change:
The repository keeps the timeline at its root. Locate it with `rg --files` and
read `TROUBLESHOOTING.md`.

Verification and outcome:
Resolved. The root timeline was found and updated; no repository content was
lost or replaced.

## 2026-08-08 22:35 CDT - Build-status jq was not on one PowerShell PATH

Command/operation:
Format the completed Cloud Build record with jq.

Symptom:
PowerShell could not find the WinGet jq shim.

Hypothesis and change:
This parent process does not inherit the newer user PATH. Prepend the known
WinGet Links directory for that invocation.

Verification and outcome:
Resolved. The retried query returned build status `SUCCESS`, all nine completed
steps, and both image digests.

## 2026-08-08 22:39 CDT - Kubernetes client lacked the GKE auth plugin

Command/operation:
First regional workload deployment.

Symptom:
Both kubeconfig entries were generated, but kubectl stopped before apply because
`gke-gcloud-auth-plugin.exe` was not installed.

Hypothesis and change:
The Windows SDK was installed without its optional GKE component. Its system
directory is not writable without elevation. Add an idempotent repo-local
installer using Google's pinned Windows archive and SHA-256, then prepend the
ignored tool directory in every Kubernetes workflow.

Verification and outcome:
Resolved. The pinned archive passed its checksum and version probe from ignored
`.tools/`; both explicit cluster contexts then authenticated successfully.

## 2026-08-08 22:44 CDT - GKE annotated the private App B Service for Ingress

Command/operation:
First post-rollout regional workload verification.

Symptom:
The Pods became ready, but the verifier rejected App B because GKE added
`cloud.google.com/neg: {"ingress":true}` to its ClusterIP Service.

Hypothesis and change:
GKE enables container-native load balancing by default and mutates otherwise
unannotated Services. App B must stay internal and needs no load-balancer NEG.
Set Google's explicit `{"ingress":false}` opt-out in the base manifest and
require that value in the live verifier.

Verification and outcome:
Resolved. The idempotent reapply set `{"ingress":false}` in both clusters.
Each cell has exact 2+2 ready Pods and passed a real App A-to-App B request;
Compute inventory contains only the intended App A NEG names.

## 2026-08-08 22:49 CDT - Autopilot occupied only one zone per region

Command/operation:
Live NEG and node inventory after the first healthy two-plus-two rollout.

Symptom:
Each regional cluster used one node in one zone, so GKE created only one App A
NEG per region. The frozen edge stack expects the same custom NEG name in all
three zones of each region.

Hypothesis and change:
GKE creates standalone NEGs only in zones occupied by the cluster. Autopilot
correctly bin-packed the small workload, while the plan assumed all regional
zones would be occupied. Strict `DoNotSchedule` topology spread is not supported
by GKE Cluster Autoscaler. Use three one-replica App A shards, each with an
exact zonal selector and its own 1-2 HPA; keep App B at two. This adds useful
zonal serving capacity without dummy Pods or manual NEG endpoints.

Verification and outcome:
Resolved. The three-plus-two rollout put one real App A Pod in every frozen
zone. GKE now owns exactly six populated `GCE_VM_IP_PORT` NEGs, with three
registered port-8080 endpoints in each region.

## 2026-08-08 22:50 CDT - Availability review guessed two manifest names

Command/operation:
Read PodDisruptionBudget settings while reviewing the zone-spread adjustment.

Symptom:
Reads for `disruption-budgets.yaml` and `availability.yaml` failed because
neither filename exists.

Hypothesis and change:
Discover the base manifest inventory first and read the actual
`pod-disruption-budgets.yaml` file.

Verification and outcome:
Resolved. The App A PDB is updated with its deployment to keep two replicas
available during voluntary disruption.

## 2026-08-08 23:04 CDT - Regional manifest checks used stale local tooling assumptions

Command/operation:
Static Terraform and Kubernetes validation for the zonal App A shard change.

Symptom:
Terraform was absent from the inherited PowerShell PATH. The first client-side
kubectl dry runs also attempted discovery at `localhost:8080`, even with
validation disabled, because no cluster context was selected.

Hypothesis and change:
This long-running process had not inherited the WinGet tool path, and kubectl
still needs discovery for these rendered resources. Prepend the known WinGet
Links path, use the ignored explicit kubeconfig and contexts, and run bounded
server-side dry runs against both real clusters.

Verification and outcome:
Resolved. Terraform validation and both server-side dry runs passed. Each
render contains exactly three App A shards, three shard HPAs, App B, and the
expected policies; no resources were changed by the dry runs.

## 2026-08-08 23:07 CDT - Workload verifier exceeded the Windows argument limit

Command/operation:
First verification pass after the three-shard rollout.

Symptom:
Windows jq failed with `Argument list too long` while checking App A placement.
All five Pods in each cell were already healthy.

Hypothesis and change:
The verifier passed the cluster's complete node inventory through jq's command
line. Validate the three Pod records in jq, then query only each serving Pod's
node and compare its live zone directly.

Verification and outcome:
Resolved. The fresh verifier passed exact three-plus-two readiness, one App A
Pod in each of the six intended zones, both immutable images, and a real local
App A-to-App B request in each region.

## 2026-08-08 23:20 CDT - Forwarding rule repeated the reserved IP version

Command/operation:
First `infra/30-lb` apply after a clean seven-add, zero-destroy plan.

Symptom:
The health check, backend service, URL map, and HTTP proxy were created, but the
global forwarding rule returned HTTP 400: `ipVersion` and `ipAddress` cannot be
specified together.

Hypothesis and change:
The reserved global address already fixes the rule to IPv4. Remove the
redundant `ip_version` field from both the core HTTP and optional HTTPS rules,
then re-plan the partial Terraform state before retrying.

Verification and outcome:
Resolved. The partial-state plan showed one add, zero changes, and zero
destroys. The retry created only the forwarding rule; live verification found
3/3 healthy regional endpoints and an HTTP 200 response at the reserved IP.
The refreshed Terraform plan reports no changes.

## 2026-08-08 23:39 CDT - Guessed Grafana image tag did not exist

Command/operation:
Started a disposable Grafana container to validate dashboard and data-source
provisioning against the real product.

Symptom:
Docker reported `manifest unknown` for the guessed `grafana/grafana:12.6.1`
tag, so no container started.

Hypothesis and change:
The data-source plugin version did not imply a matching Grafana image tag.
Inspect the official image registry and use the available Grafana `13.1.0`
image with the compatible BigQuery `3.2.0` plugin.

Verification and outcome:
Resolved. A disposable Grafana 13.1.0 instance loaded both pinned-UID data
sources and the four-panel dashboard without provisioning errors, then was
stopped and removed.

## 2026-08-08 23:39 CDT - Live Grafana gate lacks external credentials

Command/operation:
Ran `scripts/verify-grafana.sh` after its static and source-data checks passed.

Symptom:
No `GRAFANA_URL` or `GRAFANA_TOKEN` is available, so the script cannot query an
external Grafana instance or prove that its rendered panels contain data.

Hypothesis and change:
This is the accepted external SaaS bootstrap input, not a GCP data or dashboard
configuration failure. Keep credentials out of Git and stop before any Grafana
API call.

Verification and outcome:
Blocked externally. The checked-in dashboard and provisioning load in Grafana,
and BigQuery plus all three Monitoring metrics have real data from both cells.
After the URL and a session-only token are supplied, `make verify-grafana` is
the bounded continuation command.

## 2026-08-08 23:40 CDT - Hardened autoscaling verifier rejected healthy Pods

Command/operation:
Combined workload, NEG, and edge verification after adding HPA-aware checks.

Symptom:
The wrapper exceeded its normal duration. A short diagnostic showed every
workload healthy, but the workload predicate kept returning false. Trace output
then showed a node name ending in a carriage return.

Hypothesis and change:
GKE's autoscaling/v2 objects omit both generation fields used by the first
reconciliation check, and the native Windows jq shim emits CRLF. Use live
`AbleToScale` and `ScalingActive` conditions with exact replica/HPA bounds, and
strip carriage returns from jq values before passing them to kubectl or Bash
arithmetic.

Verification and outcome:
Resolved. The workload verifier passed both 3-6/2-6 regional cells and their
local requests. The NEG verifier then matched all six groups exactly to the
ready zonal Pod IPs on port 8080, three endpoints per region.

## 2026-08-08 23:46 CDT - Background mock listener was rejected locally

Command/operation:
Tried to exercise the Grafana verifier's live API branch with a PowerShell
background-job HTTP listener.

Symptom:
The command wrapper rejected the combined background-listener script before it
ran. No process started and no file or external service changed.

Hypothesis and change:
The nested background job triggered the local command policy. Replace it with
one foreground test process that owns an in-memory loopback server and invokes
the verifier as a child.

Verification and outcome:
Resolved. The mock covered both data-source health endpoints, the dashboard
read, every expected panel target, and both cell labels. The complete live
verifier branch passed and the loopback server stopped normally.

## 2026-08-09 00:09 CDT - BigQuery sink stores JSON numbers as FLOAT

Command/operation:
First BigQuery hard-gate pass after the controlled traffic seed.

Symptom:
The table existed and was time-partitioned, but the schema assertion rejected
`jsonPayload.status_code` and `latency_ms` because it expected INTEGER.

Hypothesis and change:
Cloud Logging's BigQuery sink maps JSON numeric values to FLOAT in the generated
table. Keep query-side `SAFE_CAST` checks for whole status/duration values and
verify the real stable FLOAT schema instead of assuming a hand-created type.

Verification and outcome:
Resolved. The rerun found every current-run row, zero current export errors,
and substantive results from all four checked-in queries across both regions,
both services, three decisions, latency percentiles, and trace joins.

## 2026-08-09 00:22 CDT - Failover cleanup needed stronger recovery guarantees

Command/operation:
First live failover baseline, before fault injection.

Symptom:
A safety review found that cleanup tried restoration only once, deleted its
isolated kubeconfig even if restoration failed, and did not force-kill a hung
native client after timeout. The baseline run was stopped before applying a
fault; both live fault profiles still read `0.0` afterward.

Hypothesis and change:
An interruption during a real outage must leave a usable recovery path. Add
three bounded restore attempts, timeout kill escalation, and preservation of
the exact kubeconfig/work directory when automatic restoration cannot be
confirmed.

Verification and outcome:
Resolved. Bash validation passed, both regions were independently healthy, and
the hardened runner later restored and reverified both cells during the live
experiment.

## 2026-08-09 00:31 CDT - Initial failover continuity ceiling was too tight

Command/operation:
First full run of the hardened failover gate at one request per second.

Symptom:
The fault, regional drain, restoration, and final health checks completed, but
the evidence policy rejected more than 15 transition failures. No PASS evidence
was retained, and the independent workload, NEG, and edge verifier confirmed
both cells fully recovered.

Hypothesis and change:
Fifteen seconds did not cover the frozen 30-second connection-draining window
plus application readiness and external health-check detection. Use a bounded
60-request test ceiling, forbid failed requests outside the drain window, and
report the actual count instead of implying zero downtime.

Verification and outcome:
Resolved. The final run sent 167 requests, recorded 16 failures all inside the
drain window, served six survivor-region responses after drain, and recovered
all six backends. The independent full verifier passed again after restoration.
