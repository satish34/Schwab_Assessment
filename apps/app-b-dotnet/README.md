# App B

Private .NET 8 risk engine used by the local App A service. It exposes
`POST /v1/evaluate`, `/health/live`, and `/health/ready` on port 8080.

```bash
dotnet test AppB.sln --configuration Release
docker build --tag app-b-engine:local .
```

Runtime identity comes from `RISK_REGION`, `RISK_CLUSTER`, and
`SERVICE_VERSION`. Fault settings are reloaded from `FAULT_CONFIG_PATH`; the
default path is `/etc/risk-faults/faults.json`.
