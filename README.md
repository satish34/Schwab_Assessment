# Schwab Assessment

> Candidate-authored technical assessment using synthetic data. This is not an
> official Charles Schwab product, service, or production system.

This repository runs a synthetic currency-rate board as two independent GKE
cells: Java App A serves the browser and public API through a global HTTPS load
balancer, while each cell calls only its local private .NET App B. Both cells
are eligible while healthy, and the application needs no login, customer data,
form, request body, or query input. **[Open the complete assignment
deliverables](deliverables/README.md).**
