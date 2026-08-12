# 00-bootstrap

This stack enables the assessment APIs, creates the project-scoped $30 monthly
safety budget, and requests a 96-vCPU `CPUS_ALL_REGIONS` quota ceiling for the
two three-zone Autopilot cells. The project and billing link must already
exist. It creates no workload infrastructure.

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

Google approval of a quota preference is external to Terraform. The post-apply
gate requires both the preferred and granted values to be at least 96 before a
release continues. A quota limit reserves no CPU and has no direct charge;
actual allocated GKE/Compute resources remain billable. Hard zonal placement
can still encounter provider capacity even when project quota is available.

When `DOMAIN_NAME` is non-empty, this stack also enables Cloud DNS and
Certificate Manager before `10-global` creates the optional HTTPS resources.

Local state is gitignored and must be retained for teardown. APIs remain enabled
after destroy so the final orphan check still works. Google does not delete a
quota preference through this API, so the orphan check reports it explicitly as
retained, non-billable project configuration. A shared remote backend is a
production extension, not a gate blocker.

For a new deployment, use a separate empty billing-enabled project and the
reviewed cross-file contract port described in `docs/REPRODUCE.md`. If its quota
preference already exists, import it as
`google_cloud_quotas_quota_preference.gke_all_regions_cpu_capacity` before the
first `00-bootstrap` plan, using ID
`projects/PROJECT_ID/locations/global/quotaPreferences/compute-cpus-all-regions-96`
and the same authenticated Terraform variable context as the wrapper;
otherwise no quota-preference import is needed.
