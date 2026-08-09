# 00-bootstrap

This stack enables the assessment APIs and creates the project-scoped $30
monthly safety budget. The project and billing link must already exist. It
creates no workload infrastructure.

```bash
make bootstrap
```

Set `BILLING_ACCOUNT_ID` in the ignored root `.env` or the environment first.
The budget uses Google's default email recipients: Billing Account
Administrators and Billing Account Users.

Local state is gitignored and must be retained for teardown. APIs remain enabled
after destroy so the final orphan check still works. A shared remote backend is
a production extension, not a gate blocker.
