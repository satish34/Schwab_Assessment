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
BigQuery CLI 2.1.17 successfully.

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
