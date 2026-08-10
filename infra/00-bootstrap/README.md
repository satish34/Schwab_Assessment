# 00-bootstrap

This stack enables the assessment APIs and creates the project-scoped $30
monthly safety budget. The project and billing link must already exist. It
creates no workload infrastructure.

From the repository root:

```bash
make bootstrap
```

Copy `.env.example` to the ignored root `.env`, then set its real
`BILLING_ACCOUNT_ID` and admin CIDR before running preflight or apply.
The budget uses Google's default email recipients: Billing Account
Administrators and Billing Account Users.

When `DOMAIN_NAME` is non-empty, this stack also enables Cloud DNS and
Certificate Manager before `10-global` creates the optional HTTPS resources.

Local state is gitignored and must be retained for teardown. APIs remain enabled
after destroy so the final orphan check still works. A shared remote backend is
a production extension, not a gate blocker.
