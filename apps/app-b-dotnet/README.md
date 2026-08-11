# App B

Private .NET 8 synthetic exchange-rate provider used only by the local App A
service. It exposes `GET /internal/exchange-rates`, `/health/live`, and
`/health/ready` on port 8080. The response always uses USD as its base and
returns an ordered catalog of ten predefined synthetic rate snapshots. Every
GET returns the same catalog without request input or per-Pod state; App A can
select the next entry locally on each UI refresh.

From the repository root:

```bash
(cd apps/app-b-dotnet && dotnet test AppB.sln --configuration Release)
docker build --tag app-b-engine:local apps/app-b-dotnet
```

Runtime identity comes from `SERVICE_REGION`, `SERVICE_CLUSTER`, and
`SERVICE_VERSION`. In Google token mode, `GOOGLE_CLOUD_PROJECT` is required for
trace names and to require `APP_A_IDENTITY_EMAIL` to be exactly
`currency-app-a-caller@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com`. Fault
settings are reloaded from `FAULT_CONFIG_PATH`; the default path is
`/etc/app-b-faults/faults.json`.

The deployed internal endpoint requires a Google-signed bearer ID token with
audience `https://app-b-engine.schwab-assessment.internal` and the exact
`currency-app-a-caller` service-account email. Signature, issuer, audience,
lifetime, email, and `email_verified` are checked before the request runs;
health endpoints remain open for Kubernetes. Local Compose explicitly uses
`APP_B_AUTH_MODE=disabled` in the custom `LocalCompose` environment. The
framework `Development`, `Staging`, and `Production` environments cannot start
with authentication disabled.

Rates are synthetic and are not for financial use.

`make build-app-b` and `make deploy-app-b` use the App B-only Cloud Build
definition, deployer identity, kubeconfig, and `currency-app-b` workload
overlay. The App A image and namespace are not mutated.
