# Evidence index

Verification is tied to project `schwab-assessment-gke` and immutable App A/App
B image tag `30fd8e9d60050f4b8cc93f25879883264a8ac30e`. Its release tree
`e4d40009613175a7aa569cb25d7c2d30b4ff2164` is byte-identical to sanitized
public commit `a03a5fb1c174cdeac87638b39acc3b7c401545b0`; publication-only history
sanitation changed identifiers, not release files. Raw operational output is
retained outside the public repository; this index records the proved claims
without publishing tokens, kubeconfigs, Terraform state, raw logs, or profile
payloads.

## Current release evidence

| Requirement | Verification | Proved result | Retained artifact |
|---|---|---|---|
| Release identity | Release manifest and image/workload gates | App A and App B use the same full SHA; immutable registry digests and deployed images matched | `18-release-manifest.txt` |
| Two regional GKE cells | Workload gate and focused final cluster check | Regional Autopilot clusters in `us-central1` and `us-east4`; three App A shards and two App B replicas per region were Ready | Retained verifier output |
| Private local App B | Regional workload and authentication gates | Each App A called only its cell-local App B ClusterIP; App B had no public endpoint; authenticated calls passed and anonymous calls returned `401` | Retained verifier output |
| Public HTTPS edge | Edge, NEG, certificate, and response gates | `https://satish.store` served the expected release through six healthy zonal App A Pod NEGs; only HTTPS port 443 was configured | `05-public-endpoint.png` |
| Controlled traffic and recovery | `make seed-traffic` | 318 bounded current-release requests covered success, authentication rejection, injected dependency failure, and recovery in both regions; both fault settings were restored to zero | Retained seed manifest and verifier output |
| Distributed tracing | Direct Cloud Trace gate | Trace `8a7d9229359fb6fbe0ff27aa043f09e9` proved App A server -> App A client -> App B server with exact parent IDs, service versions, and cell labels | `19-cloud-observability.txt`, `19-cloud-trace.png` |
| Java profiling | Metadata-only Cloud Profiler gate | Current-release CPU and heap profiles were present in all six zones; profile bytes were never retrieved or stored | `19-cloud-observability.txt`, `19-cloud-profiler.png` |
| Platform logs and metrics | Platform observability gate | Fresh control-plane, node, HPA, load-balancer, VPC-flow, and firewall logs; healthy-node, HPA, request, 5xx, and latency metrics; sampled LB rows in the separate 30-day dataset | `20-platform-observability.txt` |
| Cloud-hosted Grafana | Private GKE Job, API, data-source, query, and cleanup gates | A digest-pinned one-hour Job returned real data for all four required panels through a loopback-only session, then was removed | `21-gke-grafana.txt`, `08-grafana.png` |
| Error Reporting | Current Console view after controlled traffic | The intentional App B injected fault and propagated App A dependency failure were grouped; unrelated Kubernetes platform groups are excluded from the application claim | `11-error-reporting.png` |
| Team isolation | Namespace, IAM, and RBAC gates | Distinct deployers retained own-namespace workload access while peer namespace, policy, Secret, exec, attach, and port-forward access was denied; Dev had no production principal | Retained verifier output |

The final focused cluster check passed for both clusters after an aggregate
capture sampled a transient Autopilot node replacement. That aggregate capture
failed closed and published no partial artifacts. The subsequent current-state
check found both clusters conformant, all ten workload Pods Ready, all current
east nodes Ready and labeled, and both controlled fault settings restored.

## Historical resilience measurement

The last full regional-drain exercise is retained as a historical architecture
measurement, not relabeled as current-release evidence. It sent 171 requests
while `us-central1` was faulted; 18 failed during convergence, none failed
outside that interval, `us-east4` served surviving traffic, public routing
converged in 63.167 seconds, and all six backends recovered. The defensible
claim is bounded automatic recovery, not zero downtime or proof that one region
can carry peak production load.

## Drift and disabled controls

| Item | Current status | Boundary |
|---|---|---|
| Terraform drift | `10-global`, `20-cluster`, and `30-lb` reported no changes. `00-bootstrap` reported only an output refresh after the regional SSD quota grant reached 900 GB; Terraform reported no infrastructure change. | Re-run the exact saved-plan gates before any apply. |
| Cloud Armor | **IMPLEMENTED / DISABLED LIVE** | No policy is attached. Enabling it requires cost approval, a reviewed in-place plan, and bounded WAF/rate-limit evidence. |
| Binary Authorization | **IMPLEMENTED / DISABLED LIVE** | Cluster admission enforcement remains off. Enabling it requires cost approval, an in-place-only plan, and a non-persisting denial test. |
| Grafana availability | **LIVE EVIDENCE SESSION / NOT DURABLE HOSTING** | The private GKE Job was intentionally removed after capture; there is no public Grafana URL or standing Viewer service. |
| Teardown | **NOT RUN** | Run only after explicit authorization with the exact destroy confirmation and orphan check. |

## Reproducing evidence for another release

Evidence is immutable-release-specific. From the exact clean release commit,
run the workload, traffic, BigQuery, Trace/Profiler, platform, Grafana, failover,
and drift gates with the full SHA:

```bash
RELEASE_SHA="$(git rev-parse HEAD)"
make verify APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make seed-traffic APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-evidence APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-manifest \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-cloud \
  APP_A_IMAGE_TAG="$RELEASE_SHA" APP_B_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-platform
make capture-observability-grafana-start GRAFANA_IMAGE_TAG="$RELEASE_SHA"
# Save the dashboard screenshot from the printed loopback URL.
make capture-observability-grafana-verify GRAFANA_IMAGE_TAG="$RELEASE_SHA"
make capture-observability-grafana-cleanup GRAFANA_IMAGE_TAG="$RELEASE_SHA"
```

The phased observability commands promote artifacts only after their live gate
passes. They never store access tokens or Profiler payload bytes. A missing
file, placeholder, static dashboard check, or artifact from another SHA is not
equivalent to current live evidence.
