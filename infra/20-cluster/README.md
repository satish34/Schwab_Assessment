# 20-cluster

This stack reads the checked local state from `10-global` and creates two
regional Autopilot clusters. It refuses network, secondary-range, project, or
node-identity outputs that do not match the frozen contract.

Both clusters use private nodes, Dataplane V2, the Regular release channel,
Workload Identity Federation, system and workload logs, and the system metrics
needed for restart and container-utilization panels. Their public control-plane
endpoints accept only the supplied administrator `/32`.

`make clusters-plan` is the human preview. `TF_AUTO_APPROVE=1 make clusters`
regenerates a fresh internal plan and applies it only after the exact cluster
contract accepts it; the cluster path does not consume a general saved plan.
Its default rejects replacement; a one-time replacement requires a separate
explicit flag and narrower contract.

API server, controller-manager, HPA-controller, scheduler, system, and workload
logging were enabled in place on both existing clusters. The 2026-08-12
post-change check showed both clusters healthy and this stack at no changes. No
cluster was created, deleted, or replaced for that update; every later release
must run the cluster verifier and plan again.

When `ENABLE_BINARY_AUTHORIZATION=1`, both clusters enforce the project policy.
Apply that opt-in only when the live plan shows two in-place updates and no
cluster replacement. Enforcement costs about $12 per cluster-month before
Google's one-cluster billing credit. The live/default flag is `0`.

Keep this stack's local state for ordered teardown. Remove the load balancer and
App A Services first; then destroy this stack before `10-global`.
