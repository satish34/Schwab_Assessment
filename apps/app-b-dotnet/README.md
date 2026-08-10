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
`SERVICE_VERSION`. `GOOGLE_CLOUD_PROJECT` is used only to format trace resource
names. Fault settings are reloaded from `FAULT_CONFIG_PATH`; the default path
is `/etc/app-b-faults/faults.json`.

Rates are synthetic and are not for financial use.
