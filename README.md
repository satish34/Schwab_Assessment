# Schwab Assessment

This repository builds the assessment as two independent GKE cells. Java App A
is the public service and calls only its local .NET App B. A Terraform-managed
global load balancer routes to healthy App A Pod NEGs in either region.

Current status: Gate 0 passed. The dedicated project is
`schwab-assessment-gke`; no workload infrastructure has been created yet. The
$30 budget is the first bootstrap resource.

## First command

```bash
make preflight
```

The remaining Make targets are added incrementally and fail clearly until their
work package is implemented and tested.

## Key documents

- `CONTRACTS.md`: frozen names, APIs, schemas, and health behavior.
- `docs/GATE_CHECKLIST.md`: current gate and verified outcomes.
- `docs/PLAN_VS_ASSIGNMENT.md`: deliberate differences and tradeoffs.
- `TROUBLESHOOTING.md`: real failures and fixes as they occur.

Never destroy the project out of order. The load balancer must be removed
before App A Services, NEGs, and clusters.
