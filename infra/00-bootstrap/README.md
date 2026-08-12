# 00-bootstrap

This stack enables the assessment APIs, creates the project-scoped $30 monthly
safety budget, and requests these Autopilot capacity ceilings:

- 96 vCPUs across all regions; and
- 900 GB of regional SSD in both `us-central1` and `us-east4`.

The project and billing link must already exist. This stack creates no workload
infrastructure.

The hardening release enables IAM Credentials. Binary Authorization and
Container Analysis metadata APIs are enabled only when
`ENABLE_BINARY_AUTHORIZATION=1`; the live/default value is `0`. API enablement
alone would not enable paid image scanning or cluster enforcement.

The observability configuration enables the Cloud Trace, Telemetry, and Cloud
Profiler APIs. Review the saved plan before applying it.

From the repository root:

```bash
make bootstrap-plan
# Review the exact saved plan, then consume it within 30 minutes:
TF_AUTO_APPROVE=1 make bootstrap
```

Copy `.env.example` to the ignored root `.env`, then set its real
`BILLING_ACCOUNT_ID` and admin CIDR before running preflight or apply.
The budget uses Google's default email recipients: Billing Account
Administrators and Billing Account Users.

Google approval of quota preferences is external to Terraform. The post-apply
gate requires the 96-vCPU preference and both 900-GB regional SSD preferences
to be granted, reconciled, and visible as Compute limits before a release
continues. Quota ceilings allocate nothing and have no direct charge; actual
GKE/Compute resources remain billable. At the current minimum replica counts,
the 900-GB value covers the observed east high-water mark of five 100-GB
Autopilot nodes plus one surge slot for each of four Deployments reconciled in
parallel. It preserves `maxUnavailable=0` but does not guarantee provider
capacity or every HPA-maximized rollout.

When `DOMAIN_NAME` is non-empty, this stack also enables Cloud DNS and
Certificate Manager before `10-global` creates the optional HTTPS resources.

Local state is gitignored and must be retained for teardown. APIs remain enabled
after destroy so the final orphan check still works. Google does not delete a
quota preference through this API, so the orphan check reports it explicitly as
retained, non-billable project configuration. A shared remote backend is a
production extension, not a gate blocker.

For a new deployment, use a separate empty billing-enabled project and the
reviewed cross-file contract port described in `docs/REPRODUCE.md`. Import any
already-retained quota preference before the first `00-bootstrap` plan. The
exact Terraform addresses and IDs are listed there; a clean project needs no
quota-preference import.
