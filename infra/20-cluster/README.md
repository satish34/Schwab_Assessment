# 20-cluster

This stack reads the checked local state from `10-global` and creates two
regional Autopilot clusters. It refuses network, secondary-range, project, or
node-identity outputs that do not match the frozen contract.

Both clusters use private nodes, Dataplane V2, the Regular release channel,
Workload Identity Federation, system and workload logs, and the system metrics
needed for restart and container-utilization panels. Their public control-plane
endpoints accept only the supplied administrator `/32`.

When `ENABLE_BINARY_AUTHORIZATION=1`, both clusters enforce the project policy.
Apply that opt-in only when the live plan shows two in-place updates and no
cluster replacement. Enforcement costs about $12 per cluster-month before
Google's one-cluster billing credit. The live/default flag is `0`.

Keep this stack's local state for ordered teardown. Remove the load balancer and
App A Services first; then destroy this stack before `10-global`.
